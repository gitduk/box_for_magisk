# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**SingBox for Magisk** is a Magisk/KernelSU/APatch module providing transparent proxy functionality for Android devices using sing-box. The module supports three network modes (tproxy, redirect, tun) and manages iptables rules, policy routing, and process lifecycle for the sing-box proxy.

## Architecture

### Module Structure

This is a Magisk module with the following architecture:

- **Root-level scripts**: Module lifecycle hooks (`customize.sh`, `service.sh`, `action.sh`, `build.sh`)
- **`singbox/` directory**: Deployed to `/data/adb/singbox` on device, containing:
  - `bin/`: sing-box and jq binaries
  - `scripts/`: Core service management scripts (modular shell architecture)
  - `config.json`: User's sing-box configuration
  - `settings.ini`: Module settings (network_mode, ipv6, ap_list)
  - `include.list` / `exclude.list`: Application filtering (whitelist/blacklist)
  - `logs/`: Runtime logs with automatic rotation
  - `ui/`: Web UI assets for sing-box dashboard

### Script Architecture (Modular Design)

The codebase follows a **modular shell script architecture** with clear separation of concerns:

**Core Dependencies (source order matters):**
```
constants.sh         # All constants and paths (must load first)
    ↓
utils.sh            # Utility functions (depends on constants)
    ↓
config.sh           # Configuration loading (depends on constants + utils)
    ↓
service.sh          # Main service orchestration
iptables.sh         # Network rules management
```

**Key Scripts:**

1. **`constants.sh`**: Centralized constants definition
   - Paths, ports, timeouts, network constants
   - Intranet IPv4/IPv6 ranges
   - Never modify these directly; they define the entire system's contract

2. **`utils.sh`**: Reusable utility functions
   - Logging with color-coded levels (info/warn/error/debug)
   - Process management (check_process_running, safe_kill, force_kill)
   - Log rotation (automatic when files exceed LOG_MAX_SIZE)
   - File operations, validation helpers

3. **`config.sh`**: Configuration loading and validation
   - Loads `config.json` using jq to extract ports/inbound config
   - Loads `settings.ini` for user preferences
   - Validates configuration and provides friendly error messages
   - Builds intranet address lists including FakeIP ranges

4. **`service.sh`**: Main service orchestration
   - Commands: start, stop, restart, force-stop, status, health
   - Startup sequence: cleanup → validate config → start process → setup iptables → setup IPv6
   - Health checks: process status, config integrity, log errors, network connectivity

5. **`iptables.sh`**: Network rules management
   - Implements three modes: redirect (TCP only), tproxy (TCP+UDP), tun (virtual interface)
   - Creates custom chains: BOX_EXTERNAL, BOX_LOCAL, BOX_IP_V4, BOX_IP_V6
   - Handles application filtering (include/exclude lists via UIDs)
   - Policy routing setup for tproxy mode (fwmark-based routing)
   - IPv6 support with parallel rule structures

6. **`diagnose.sh`**: System diagnostics (not shown but referenced)
7. **`rmlimit.sh`**: Removes vendor network restrictions (called during cleanup)

### Configuration Validation Strategy

The module has **strict configuration validation** with user-friendly error messages:

- `network_mode` in `settings.ini` must match inbound type in `config.json`
- If mismatch detected, shows example configuration with detailed suggestions
- Validates ports, checks TUN device availability, falls back gracefully (TUN → tproxy)
- Config errors include context and actionable fixes, not just "failed"

### Critical Implementation Details

**Process Management:**
- TUN mode runs with full root privileges (needs `CAP_NET_ADMIN` capability)
- Other modes (tproxy/redirect) use `busybox setuidgid root:net_admin` for security
- Wait loops with `MAX_RETRIES` and `RETRY_INTERVAL` for process startup verification
- Graceful shutdown (SIGTERM) with fallback to force kill (SIGKILL) after timeout
- Always cleanup iptables rules before start to ensure clean state

**iptables Architecture:**
- Custom chains avoid polluting system chains
- Order matters: check established connections first (optimization)
- Bypass intranet traffic early to avoid routing loops
- Application filtering by UID (Android's package → UID mapping)
- Cleanup must remove chain references from main chains before deleting chains

**Logging System:**
- Dual output: stdout (colorized for TTY) + log files
- Automatic log rotation at 10MB with 3 backups
- Updates `module.prop` description in real-time for Magisk Manager visibility
- Log levels: info (green), warn (yellow), error (red), debug (cyan)

**IPv6 Handling:**
- Completely separate rule set (ip6tables) paralleling IPv4
- Policy routing with IPv6 fwmark and route table 2024
- Can be disabled via `ipv6="false"` in `settings.ini`
- Adds unreachable rule when IPv6 disabled to prevent leaks

**Application Filtering Priority:**
- `exclude.list` > `include.list` (exclude takes precedence)
- Also reads config.json's `exclude_package[]` / `include_package[]` arrays
- Merged and deduplicated package lists
- Uses `pm list packages -U` to resolve package names → UIDs

**Network Mode Implementation:**

1. **redirect mode**: Uses `REDIRECT` target in nat table (TCP only, UDP direct)
   - Redirects TCP to `redir_port` from config.json
   - Simpler, better compatibility, but UDP not proxied

2. **tproxy mode**: Uses `TPROXY` target in mangle table (TCP + UDP)
   - Requires policy routing setup (fwmark 16777216/16777216, table 2024)
   - Marks packets → routing table → local delivery to tproxy_port
   - Best performance and functionality (recommended)

3. **tun mode**: Uses virtual network interface
   - Least iptables rules (just FORWARD chain accepts)
   - sing-box handles routing via TUN interface
   - Checks TUN device availability (`/dev/net/tun`)
   - Sets TUN device permissions to 0666 for accessibility
   - Runs sing-box with full root privileges (no setuidgid)
   - Attempts SELinux context adjustment if chcon available
   - Auto-fallback to tproxy if TUN not available

## Common Development Tasks

### Building the Module

```bash
# Build the Magisk/KernelSU/APatch module ZIP
./build.sh
```

This creates `box_for_magisk-vX.X.X.zip` by:
- Reading version from `module.prop`
- Zipping all files except `.git/`, `.github/`, `docs/`, `build.sh`, `README.md`, `LICENSE`

### Testing and Debugging

**Service Management:**
```bash
# Start service with full logging
/data/adb/singbox/scripts/service.sh start

# Check status (shows uptime, memory, recent logs)
/data/adb/singbox/scripts/service.sh status

# Health check (comprehensive diagnostics)
/data/adb/singbox/scripts/service.sh health

# Graceful stop
/data/adb/singbox/scripts/service.sh stop

# Force stop (SIGKILL)
/data/adb/singbox/scripts/service.sh force-stop

# Restart (stop + reload config + start)
/data/adb/singbox/scripts/service.sh restart
```

**Configuration Validation:**
```bash
# Validate sing-box config without starting
/data/adb/singbox/bin/sing-box check -D /data/adb/singbox/ -C /data/adb/singbox
```

**Manual iptables Management:**
```bash
# Apply tproxy rules manually
/data/adb/singbox/scripts/iptables.sh tproxy

# Apply redirect rules
/data/adb/singbox/scripts/iptables.sh redirect

# Apply tun rules
/data/adb/singbox/scripts/iptables.sh tun

# Clear all rules
/data/adb/singbox/scripts/iptables.sh clear
```

**Log Inspection:**
```bash
# Real-time service log
tail -f /data/adb/singbox/logs/box.log

# Real-time script execution log
tail -f /data/adb/singbox/logs/run.log

# Check for errors
grep ERROR /data/adb/singbox/logs/box.log | tail -20
```

**Debugging iptables:**
```bash
# View mangle table rules (tproxy mode)
iptables -t mangle -L -n -v

# View nat table rules (redirect mode)
iptables -t nat -L -n -v

# Check policy routing
ip rule list
ip route show table 2024

# IPv6 routing (if enabled)
ip -6 rule list
ip -6 route show table 2024
```

**Process Inspection:**
```bash
# Find sing-box process
ps | grep sing-box

# Check process ownership
ls -l /proc/$(pidof sing-box)/

# Memory usage
cat /proc/$(pidof sing-box)/status | grep VmRSS
```

## Code Modification Guidelines

### When Modifying Scripts

1. **Always maintain source order**: `constants.sh` → `utils.sh` → `config.sh` must load in this order
2. **Test all three network modes**: changes to iptables.sh must work for redirect, tproxy, and tun
3. **Handle both IPv4 and IPv6**: most networking code needs parallel IPv6 implementation
4. **Use existing utility functions**: Don't reinvent logging, process checks, or file operations
5. **Validate early, fail gracefully**: Check preconditions and provide actionable error messages
6. **Clean up resources**: Always cleanup iptables rules and policy routing on stop/error

### Adding New Features

**Adding a new configuration option:**
1. Add constant to `constants.sh` if it's system-wide
2. Add loading logic to `config.sh` (either from settings.ini or config.json)
3. Add validation with user-friendly error messages
4. Export the variable for other scripts to use
5. Update `show_config_summary()` to display the new option

**Adding a new service command:**
1. Add case in `service.sh` main() function
2. Create a dedicated function following the naming pattern
3. Ensure proper logging at info/warn/error levels
4. Update usage message in the `*)` case

**Modifying iptables rules:**
1. Test changes with `iptables.sh` directly first (not through service.sh)
2. Verify cleanup works correctly (rules fully removed)
3. Check that rules don't cause routing loops
4. Test with both include and exclude lists populated
5. Verify IPv6 behavior when `ipv6="true"`

### Shell Script Best Practices for This Codebase

- **Use `set -e` carefully**: Only in iptables.sh with proper trap handlers
- **Quote all variables**: Use `"${variable}"` not `$variable` to handle spaces
- **Check command existence**: Use `command_exists` before calling optional commands
- **Avoid bashisms**: This is POSIX sh, not bash (use `[ ]` not `[[ ]]`, avoid arrays for most uses)
- **Use `busybox` commands**: Prefix with `busybox` when available for consistency
- **Always log operations**: Use `log info/warn/error` liberally for debugging
- **Handle Android quirks**: Android's shell environment is limited (no `pidof`, limited `df`, etc.)

### Critical Areas (High Risk of Breaking)

1. **iptables chain ordering**: Wrong order breaks traffic or causes loops
2. **Policy routing setup**: Incorrect fwmark or table number breaks tproxy mode
3. **Process startup wait logic**: Too short = false negatives, too long = slow starts
4. **Configuration validation**: Must catch mismatches between settings.ini and config.json
5. **IPv6 cleanup**: Easy to forget IPv6 rules when cleaning up IPv4 rules
6. **Application UID resolution**: Package manager queries are Android-version specific

## Important Files

- **`module.prop`**: Module metadata (id, version, description) - update versionCode for each release
- **`singbox/settings.ini`**: User-editable settings (network_mode, ipv6, ap_list)
- **`singbox/config.json`**: User's sing-box configuration (not in repo, user provides)
- **`singbox/scripts/constants.sh`**: System constants (modify with extreme care)
- **`customize.sh`**: Magisk install hook (runs during module installation)
- **`service.sh`**: Magisk boot hook (runs at device boot after network ready)
- **`action.sh`**: Quick toggle script for manual service start/stop

## Testing Checklist

Before committing changes:

- [ ] Test all three network modes (redirect, tproxy, tun)
- [ ] Test with IPv6 enabled and disabled
- [ ] Test with include.list and exclude.list populated
- [ ] Verify clean startup (no leftover rules from previous runs)
- [ ] Verify clean shutdown (all rules removed, routes cleaned)
- [ ] Check logs for errors or warnings
- [ ] Test configuration validation (intentionally break config.json)
- [ ] Test TUN fallback (make /dev/net/tun unavailable)
- [ ] Verify log rotation works (force log file > 10MB)
- [ ] Test health check command

## Common Pitfalls

1. **Forgetting to cleanup iptables before start**: Always clear rules first to avoid duplicates
2. **Not testing IPv6 code paths**: IPv6 logic often parallels IPv4 but has subtle differences
3. **Assuming busybox commands exist**: Android environments vary; use `command_exists` checks
4. **Hardcoding paths**: Always use constants from `constants.sh`
5. **Not handling config.json inbound mismatches**: Users frequently set wrong network_mode
6. **Ignoring process startup timing**: sing-box takes time to start; wait and verify
7. **Breaking module.prop updates**: The `sed` command for description must handle special chars
8. **Not preserving config.json on upgrades**: customize.sh backs it up, verify this works
9. **Forgetting to export variables**: config.sh loads vars but must export for other scripts
10. **TUN mode permission errors**: TUN device requires 0666 permissions and full root capabilities; using setuidgid will cause "permission denied" errors

## Version Information

Current version: v1.3.1 (versionCode: 20260118)

Recent major changes (v1.3.0+):
- Refactored to modular shell script architecture
- Added health check functionality
- Automatic log rotation
- Improved IPv6 support with parallel rule structures
- Enhanced error handling and user-friendly validation messages
- Automatic permission fixing on startup
- Graceful TUN fallback to tproxy mode
