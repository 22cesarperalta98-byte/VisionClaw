"""VisionClaw voice agent: LiveKit room <-> realtime model, tools via the gateway.

The phone publishes mic + camera into a LiveKit room and this worker joins as
the assistant. Which brain answers is the user's choice, carried in their
participant metadata: Gemini Live (native audio+video) or OpenAI Realtime
(gpt-realtime-2; video frames arrive as image items). The framework owns what
the direct-connection client had to hand-roll -- echo cancellation lives in
WebRTC on the phone, interruption is playback-position-aware here.

Per-user identity: the room token's identity IS the gateway userId, so tool
calls hit the gateway with the service token plus X-User-Id, landing in that
user's own CMA session, vault and calendar.

Env (Fly secrets): LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET,
GOOGLE_API_KEY, OPENAI_API_KEY (optional; absent disables the openai engine),
GATEWAY_URL, GATEWAY_SERVICE_TOKEN. Models via GEMINI_MODEL /
OPENAI_REALTIME_MODEL.
"""

import asyncio
import json
import logging
import os
from dataclasses import dataclass

import aiohttp
from livekit.agents import (
    Agent,
    AgentSession,
    JobContext,
    RoomInputOptions,
    RunContext,
    WorkerOptions,
    cli,
    function_tool,
)
from livekit.plugins import google, openai

logger = logging.getLogger("visionclaw-agent")

INSTRUCTIONS = """You are VisionClaw, an AI assistant the user talks to while showing you the
world through their phone camera or smart glasses. Keep responses concise and natural.

You can see live video. Answer visual questions directly from what you see.

For anything requiring action or lookup beyond your sight -- messages, web search, lists,
reminders, calendars, research, smart home -- use the execute tool. Speak a brief natural
acknowledgment BEFORE calling it, never call it silently. Results may arrive as a follow-up;
relay them as the answer to what was asked, not as a notification."""


@dataclass
class Userdata:
    user_id: str


# How long a tool call may hold the model's turn open before the answer is
# demoted to a follow-up. Past this, users assume the call is dead and hang up
# -- which kills the session, the tool call, and the answer with it.
QUICK_ANSWER_S = 18

# The gateway echoes this ack when a task outlives its own 110s wait; it is an
# instruction blob for a voice model, not an answer, so never relay it as one.
GATEWAY_DEFERRAL_PREFIX = "[task started]"

_relay_tasks: set[asyncio.Task] = set()


async def _gateway_execute(user_id: str, task: str) -> str:
    gateway = os.environ["GATEWAY_URL"].rstrip("/")
    token = os.environ["GATEWAY_SERVICE_TOKEN"]
    async with aiohttp.ClientSession() as http:
        async with http.post(
            f"{gateway}/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {token}",
                "X-User-Id": user_id,
            },
            json={"messages": [{"role": "user", "content": task}]},
            timeout=aiohttp.ClientTimeout(total=120),
        ) as resp:
            body = await resp.json()
    try:
        return body["choices"][0]["message"]["content"]
    except (KeyError, IndexError):
        logger.warning("gateway returned unexpected shape: %s", json.dumps(body)[:300])
        return "The action agent returned an unexpected response."


@function_tool
async def execute(ctx: RunContext[Userdata], task: str) -> str:
    """Delegate an action or lookup to the user's personal action agent: sending
    messages, web search, managing lists and reminders, Google Calendar, research,
    notes, smart home control. Describe the task completely, with names, content
    and platforms."""
    logger.info("execute start: user=%s task=%r", ctx.userdata.user_id, task[:200])
    job = asyncio.ensure_future(_gateway_execute(ctx.userdata.user_id, task))
    done, _ = await asyncio.wait({job}, timeout=QUICK_ANSWER_S)
    if done:
        result = await job
        logger.info("execute quick result: user=%s len=%d", ctx.userdata.user_id, len(result))
        return result

    # Slow path: free the model to keep talking, then speak the result when it
    # lands. If the user hangs up first the reply fails here (logged), but the
    # answer survives in their CMA session -- asking again next call is instant.
    session = ctx.session

    async def relay() -> None:
        try:
            result = await job
        except Exception:
            logger.exception("execute background task failed: user=%s", ctx.userdata.user_id)
            result = None
        if result is None:
            instructions = (
                "The background task failed. Tell the user briefly and offer to try again."
            )
        elif result.startswith(GATEWAY_DEFERRAL_PREFIX):
            logger.info("execute deferred past gateway wait: user=%s", ctx.userdata.user_id)
            instructions = (
                "The background task is taking longer than expected and is still running. "
                "Tell the user briefly; they can ask for the result in a bit."
            )
        else:
            logger.info("execute late result: user=%s len=%d", ctx.userdata.user_id, len(result))
            instructions = (
                "The result of the earlier background task just arrived. Relay it naturally "
                f"as the answer to what the user asked:\n\n{result}"
            )
        try:
            session.generate_reply(instructions=instructions)
        except Exception:
            logger.warning("execute result arrived after session closed: user=%s", ctx.userdata.user_id)

    t = asyncio.create_task(relay())
    _relay_tasks.add(t)
    t.add_done_callback(_relay_tasks.discard)
    return (
        "[running] The task needs more time and keeps running in the background. Tell the user "
        "briefly, in your own words, that you're still on it -- do NOT guess at the answer. "
        "The real result will arrive shortly as a follow-up for you to relay."
    )


def build_llm(engine: str):
    if engine == "openai":
        if not os.environ.get("OPENAI_API_KEY"):
            logger.warning("openai engine requested but OPENAI_API_KEY unset; using gemini")
        else:
            return openai.realtime.RealtimeModel(
                model=os.environ.get("OPENAI_REALTIME_MODEL", "gpt-realtime-2.1"),
            )
    return google.beta.realtime.RealtimeModel(
        model=os.environ.get("GEMINI_MODEL", "gemini-2.5-flash-native-audio-preview-12-2025"),
        voice=os.environ.get("GEMINI_VOICE", "Puck"),
    )


async def entrypoint(ctx: JobContext):
    await ctx.connect()

    # The phone's room token carries identity (= gateway userId) and metadata
    # (= engine choice from Settings). Both decided client-side, minted
    # server-side, read here.
    participant = await ctx.wait_for_participant()
    try:
        meta = json.loads(participant.metadata) if participant.metadata else {}
    except json.JSONDecodeError:
        meta = {}
    engine = meta.get("engine", "gemini")
    user_id = participant.identity or "demo"
    logger.info("session start: user=%s engine=%s", user_id, engine)

    session = AgentSession(
        llm=build_llm(engine),
        userdata=Userdata(user_id=user_id),
    )

    await session.start(
        agent=Agent(instructions=INSTRUCTIONS, tools=[execute]),
        room=ctx.room,
        # Video is opt-in (RoomInputOptions.video_enabled defaults to False);
        # without this the model gets no frames and hallucinates a scene when
        # asked what it sees.
        room_input_options=RoomInputOptions(video_enabled=True),
    )


if __name__ == "__main__":
    cli.run_app(WorkerOptions(entrypoint_fnc=entrypoint))
