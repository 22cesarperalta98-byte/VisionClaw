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


@function_tool
async def execute(ctx: RunContext[Userdata], task: str) -> str:
    """Delegate an action or lookup to the user's personal action agent: sending
    messages, web search, managing lists and reminders, Google Calendar, research,
    notes, smart home control. Describe the task completely, with names, content
    and platforms."""
    gateway = os.environ["GATEWAY_URL"].rstrip("/")
    token = os.environ["GATEWAY_SERVICE_TOKEN"]
    async with aiohttp.ClientSession() as http:
        async with http.post(
            f"{gateway}/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {token}",
                "X-User-Id": ctx.userdata.user_id,
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
