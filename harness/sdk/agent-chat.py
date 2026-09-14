"""Agent-first terminal chat built on the official DeepSeek Harness Python SDK.

Claude Code-style input: every line typed is a prompt to the agent unless it
starts with "!", which runs the rest as a bash command; :q / exit / quit
leaves the chat. Unlike one-shot `omarchy agent prompt`, all prompts share
one persistent SDK session, so the agent keeps the conversation context.

The SDK runtime is the dsh `sdk-minimal` profile subprocess under
~/.local/share/omarchy-dshsdk (see the README "Running the Harness" section
for how it is provisioned). The model is reached through the local gateway
(llm-gw.local:8443, self-signed CA trusted via NODE_EXTRA_CA_CERTS),
the officially supported way: DEEPSEEK_BASE_URL/DEEPSEEK_API_KEY injection.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

from deepseek_harness import DeepSeekHarness
from deepseek_harness.errors import HarnessError

SDK_BASE = Path.home() / ".local/share/omarchy-dshsdk"
GATEWAY_URL = "https://llm-gw.local:8443"
MODEL = "deepseek-v4-flash"


def gateway_api_key() -> str:
    """Read the gateway key from the SDK credentials file (ANTHROPIC_AUTH_TOKEN ref)."""
    creds_path = SDK_BASE / ".credentials.yaml"
    match = re.search(r"ANTHROPIC_AUTH_TOKEN:\s*(\S+)", creds_path.read_text())
    if not match:
        sys.exit(f"omarchy-agent-chat: gateway key missing from {creds_path}")
    return match.group(1)


def main() -> int:
    dsh_home = SDK_BASE / "dsh-home"

    # The dsh runtime is a node subprocess: it must trust the gateway's
    # self-signed CA and reach llm-gw.local directly (the QEMU user-net
    # host alias 10.0.2.2), not through the VM's HTTP proxy.
    os.environ["NODE_EXTRA_CA_CERTS"] = str(dsh_home / "llm-gw.crt")
    no_proxy = "llm-gw.local,localhost,127.0.0.1,10.0.2.2"
    os.environ["NO_PROXY"] = no_proxy
    os.environ["no_proxy"] = no_proxy

    print(f"omarchy agent chat — dsh sdk session ({MODEL} via {GATEWAY_URL})")
    print("plain text asks the agent; !<cmd> runs bash; :q quits\n")

    with DeepSeekHarness(
        provider="deepseek-official",
        model=MODEL,
        cwd=os.getcwd(),
        dsh_home=str(dsh_home),
        profile="sdk-minimal",
        base_url=GATEWAY_URL,
        api_key=gateway_api_key(),
    ) as harness:
        session = harness.start_session()
        while True:
            try:
                line = input("\033[36m❯\033[0m ")
            except EOFError:
                print()
                return 0
            except KeyboardInterrupt:
                print()
                continue
            if not line.strip():
                continue
            if line in (":q", "exit", "quit"):
                return 0
            if line.startswith("!"):
                subprocess.run(line[1:], shell=True)
                print()
                continue
            try:
                result = session.run(line)
            except KeyboardInterrupt:
                print("\n(interrupted)")
                continue
            except HarnessError as exc:
                print(f"error: {exc}\n")
                continue
            answer = result.final_response.strip()
            print(answer or f"(no response; finish_reason={result.finish_reason})")
            print()


if __name__ == "__main__":
    sys.exit(main())
