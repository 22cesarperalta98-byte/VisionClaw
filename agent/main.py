"""VisionClaw voice agent: LiveKit room <-> Gemini Live, tools via the gateway.

The phone publishes mic + camera into a LiveKit room and this worker joins as
the assistant: the google plugin drives Gemini Live (audio and video natively),
and the framework owns everything the direct-connection client had to hand-roll
-- echo cancellation lives in WebRTC on the phone, interruption is playback-
position-aware here, VAD and turn-taking are configurable in one place.

Env (Fly secrets): LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET,
GOOGLE_API_KEY, GATEWAY_URL, plus GEMINI_MODEL to swap voice engines.
"""

import json
import logging
import os

import aiohttp
from livekit.agents import Agent, AgentSession, JobContext, WorkerOptions, cli, function_tool
from livekit.plugins import google

logger = logging.getLogger("visionclaw-agent")

INSTRUCTIONS = """You are VisionClaw, an AI assistant the user talks to while showing you the
world through their phone camera or smart glasses. Keep responses concise and natural.

You can see live video. Answer visual questions directly from what you see.

For anything requiring action or lookup beyond your sight -- messages, web search, lists,
reminders, calendars, research, smart home -- use the execute tool. Speak a brief natural
acknowledgment BEFORE calling it, never call it silently. Results may arrive as a follow-up;
relay them as the answer to what was asked, not as a notification."""


@function_tool
async def execute(task: str) -> str:
    """Delegate an action or lookup to the user's personal action agent: sending
    messages, web search, managing lists and reminders, Google Calendar, research,
    notes, smart home control. Describe the task completely, with names, content
    and platforms."""
    gateway = os.environ["GATEWAY_URL"].rstrip("/")
    token = os.environ["GATEWAY_SERVICE_TOKEN"]
    async with aiohttp.ClientSession() as http:
        async with http.post(
            f"{gateway}/v1/chat/completions",
            headers={"Authorization": f"Bearer {token}"},
            json={"messages": [{"role": "user", "content": task}]},
            timeout=aiohttp.ClientTimeout(total=120),
        ) as resp:
            body = await resp.json()
    try:
        return body["choices"][0]["message"]["content"]
    except (KeyError, IndexError):
        logger.warning("gateway returned unexpected shape: %s", json.dumps(body)[:300])
        return "The action agent returned an unexpected response."


async def entrypoint(ctx: JobContext):
    await ctx.connect()

    session = AgentSession(
        llm=google.beta.realtime.RealtimeModel(
            model=os.environ.get("GEMINI_MODEL", "gemini-2.5-flash-native-audio-preview-12-2025"),
            voice=os.environ.get("GEMINI_VOICE", "Puck"),
        ),
    )

    await session.start(
        agent=Agent(instructions=INSTRUCTIONS, tools=[execute]),
        room=ctx.room,
    )


if __name__ == "__main__":
    cli.run_app(WorkerOptions(entrypoint_fnc=entrypoint))
