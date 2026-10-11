<div align="center">

<img width="100%" alt="header" src="https://capsule-render.vercel.app/api?type=waving&height=210&text=Diggominer%20Bot&fontAlign=50&fontAlignY=36&fontSize=56&desc=Mining%20Claim%20%7C%20Task%20Rewards%20%7C%20Proxy%20Support&descAlign=50&descAlignY=58"/>

<img alt="typing" src="https://readme-typing-svg.demolab.com?font=Inter&size=18&duration=3000&pause=650&center=true&vCenter=true&width=900&lines=Mining+Claim+Automation;Daily+Tasks+%7C+Social+Tasks+%7C+Streak+Rewards;Referral+Bonus+%7C+Friend+Rank;Multi-Account+%7C+Sequential+Processing;Proxy+Support+%7C+One+Proxy+Per+Account"/>

<p>
  <img alt="elixir" src="https://img.shields.io/badge/Elixir-1.14%2B-4B275F?logo=elixir&logoColor=white"/>
  <img alt="platform" src="https://img.shields.io/badge/Platform-Diggominer-111111"/>
  <img alt="multi-account" src="https://img.shields.io/badge/Multi--Account-Supported-111111"/>
  <img alt="proxy" src="https://img.shields.io/badge/Proxy-Supported-111111"/>
  <img alt="author" src="https://img.shields.io/badge/by-Yuurisandesu-111111"/>
</p>

<p>
  <b>Diggominer Bot</b> is a full automation bot for the Diggominer Telegram Miniapp.<br/>
  It handles the complete daily cycle: the eight hour mining claim, daily task rewards, the X social tasks with their confirmation window, the seven day streak calendar, the referral bonus and the friend rank, all running automatically across multiple accounts with proxy support and a live countdown between cycles.<br/>
  Built and distributed by <b>Yuurisandesu</b>.
</p>

</div>

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Running the Bot](#running-the-bot)
- [Features](#features)
- [File Structure](#file-structure)
- [Disclaimer](#disclaimer)

---

## Requirements

- Elixir `1.14+` with Erlang/OTP `25+`
- Git

---

## Installation

### Install Elixir

Elixir runs on the Erlang virtual machine, so **Erlang/OTP is required** Elixir cannot run without
it. Every package manager below installs Erlang/OTP for you as a dependency. The only path that needs
a separate Erlang step is the Windows manual installer (see below).

**Windows:**

*Option A package manager (recommended, installs Erlang automatically):*

```cmd
winget install Elixir.Elixir
```

*Option B manual installer (two installers, in this order):*

1. Download and run the **Erlang/OTP installer** from https://www.erlang.org/downloads
2. Run `erl -s halt` to check which OTP version you got
3. Download the **Elixir installer built for that exact OTP** from https://elixir-lang.org/install.html (`elixir-otp-<N>.exe`) and run it

Then open Command Prompt and verify:

```cmd
elixir --version
```

The output prints both versions, for example `Elixir 1.14.0 (compiled with Erlang/OTP 25)`.

**Linux (Ubuntu / Debian):**

```bash
sudo apt-get update
sudo apt-get install -y elixir
elixir --version
```

**macOS:**

```bash
brew install elixir
elixir --version
```

> If you do not have Homebrew, install it first from https://brew.sh

**Termux (Android):**

```bash
pkg update && pkg upgrade -y
pkg install elixir -y
elixir --version
```

> If the `elixir` package is not available in your Termux repository, install an Ubuntu environment first with `pkg install proot-distro`, then `proot-distro install ubuntu`, then `proot-distro login ubuntu` and run the Linux command above inside it.

---

### Clone and Install

**Clone the repository:**

```bash
git clone https://github.com/Yuurisan-N1/Diggo-Miniapp.git
cd Diggo-Miniapp
```

**Install dependencies:**

This bot uses only the Elixir standard library, so there is nothing to install. Erlang/OTP was already installed by the step above.

---

## Configuration

### 1. Accounts (data.txt)

Fill `data.txt` with Telegram WebApp `initData` for each account, one per line:

```
user=%7B%22id%22...&hash=abc123
user=%7B%22id%22...&hash=def456
```

> `initData` can be obtained from the browser DevTools when opening the Diggominer Miniapp on Telegram Web. The account is identified by the `initData` itself, so no separate id column is needed.
>
> The Diggominer server accepts an `initData` for a **short window only** (measured: about five minutes from the moment Telegram minted it), so copy it and start the bot right away. After the first successful sign in the bot keeps the long lived session token in memory, so every later cycle keeps working even when the `initData` itself has already aged out. Restarting the bot needs a freshly copied `initData`.

### 2. Proxy (proxy.txt)

Fill `proxy.txt` with proxies, one per line (optional, leave empty to run without proxy):

```
host:port
host:port:user:pass
http://user:pass@host:port
```

Proxies are assigned to accounts by index in round-robin order.

### 3. Bot Settings (config.json)

`sleep_seconds` controls how many seconds the bot waits between cycles. If `config.json` is missing, it is created automatically with a default of `3600` seconds.

```json
{
  "settings": {
    "sleep_seconds": 3600
  }
}
```

---

## Running the Bot

**Linux / macOS:**

```bash
elixir --erl "+Bd" bot.exs
```

**Windows:**

```cmd
elixir --erl "+Bc" bot.exs
```

Or just double click `run_pc.bat`, which runs the Windows command above.

---

## Features

### Account State
At the start of every account the bot signs in with the `initData` and logs the account name together with the current DIGGO balance. An account whose `initData` is refused is reported and skipped before any other request is sent.

### Mining Cycle
The mining pool accrues for eight hours and the server publishes the exact moment it becomes claimable. While the pool is still accruing the bot prints how much time is left and moves straight on to the next phase it never parks the cycle on a multi-hour countdown, so every account is processed on every pass. When the pool is ready the claim is sent and the amount the server credits is logged.

### Daily Tasks
Every task the server reports as due is processed in a fixed order: the daily check in, the Telegram community task, the X social tasks, the invite task, the map level task and the reward ad. A task that was already completed is passed over instead of being claimed twice, and a task that still needs a manual channel join is reported as such. Every task is claimed with a fresh idempotency key, so a repeated cycle can never credit the same task twice.

### Social Tasks
The X follow and X post tasks are self reported, so the server opens a confirmation window before the reward is claimable. The bot opens the attempt, waits out that window with a live countdown, confirms the attestation and then claims the reward.

### Daily Streak
The seven day reward calendar is read from the account state. Every day the server marks as available is claimed in order and logged with the amount it credited, and the streak counter the server keeps is read back instead of being guessed.

### Referral Bonus
The referral commission is collected when the server reports one pending. Accounts with nothing pending are reported as such.

### Friend Rank
The account's own position on the friend leaderboard is read from the account state and printed together with the number of friends it has.

### Map Progress
The map level and the experience the account has earned toward the next level are logged at the end of the account block.

### Multi Account
All accounts in `data.txt` are processed sequentially within every cycle. Each account block starts with its own proxy line, and blocks are separated by one blank line so the mapping between an account and its egress is auditable in the log.

### Proxy Support
Proxies are loaded from `proxy.txt` and assigned to accounts by position in round-robin order. Proxy credentials are masked in log output. Running without proxies is fully supported.

### Auto Countdown
Every wait inside the cycle displays a live `HH:MM:SS` countdown in place, and after all accounts complete a cycle the bot shows a countdown until the next cycle starts. A mining cycle that is still accruing is reported as a single line instead, so it never stalls the rest of the cycle.

---

## File Structure

```text
Diggo-Miniapp/
├── bot.exs         # Main bot, full daily cycle automation
├── config.json     # Sleep duration between cycles
├── data.txt        # Account initData, one per line
├── proxy.txt       # Proxy list, one per line (optional)
├── run_pc.bat      # Launcher for Windows
├── LICENSE         # License file
└── utils/
    ├── banner.ex   # Banner display on startup
    └── json.ex     # JSON encoder and decoder
```

---

## Disclaimer

This tool is built for educational and technical exploration purposes. Use it wisely and at your own responsibility.

---

<div align="center">
<img width="100%" alt="footer" src="https://capsule-render.vercel.app/api?type=waving&height=120&section=footer"/>
</div>