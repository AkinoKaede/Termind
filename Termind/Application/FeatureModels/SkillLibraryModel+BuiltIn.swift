import AgentKit
import Foundation

/// The skills Termind ships with.
///
/// They exist so the feature is something the user *edits* rather than
/// something they have to invent. A library that starts empty asks a new user to
/// guess the format, the register, and the useful level of detail before they
/// have seen one work; three real runbooks answer all three, and the fastest way
/// to write a fourth is to open one of these and change it.
///
/// Ordinary skills in every other respect. They are copied into the library on
/// first launch and are the user's from that moment: editable, disableable, and
/// deletable, with nothing putting them back. The generation mark is what makes
/// that stick — seeding installs only what a later release added, so a skill
/// deleted today does not return tomorrow.
///
/// English, in every locale, and deliberately not in the string catalog. A
/// skill's body is model-facing prose that happens to be readable — the same
/// register as `AgentPlanContractInjection.contract` — and these are records the
/// user owns and rewrites from the moment they arrive. Translating them would
/// mean either rewriting someone's edited copy when they change languages, or
/// carrying two versions of six kilobytes of shell commentary that must not
/// drift apart. The user's own skills are written in whatever language they
/// write in; these are a starting point they are free to translate or replace.
///
/// The content is deliberately about *this* app's shape of work. Two are
/// investigations that stay read-only until they have something to say, and one
/// teaches the pull/edit/push loop that keeps a remote file's contents out of
/// the conversation entirely.
nonisolated enum AgentSkillLibrary {
    /// Bumped when a release adds starter skills, never for edits to existing
    /// ones — a user's copy is theirs, and rewriting it under them would throw
    /// away whatever they changed.
    static let currentGeneration = 1

    static func builtIns(after generation: Int) -> [AgentSkill] {
        all.filter { $0.generation > generation }.map(\.skill)
    }

    private static var all: [(generation: Int, skill: AgentSkill)] {
        [
            (1, diskFullTriage), (1, failingService), (1, safeConfigEdit),
        ]
    }

    private static var diskFullTriage: AgentSkill {
        AgentSkill(
            name: "disk-full-triage",
            title: "Disk Full Triage",
            summary: """
                Find what filled a disk and decide what is safe to reclaim. Use when a filesystem \
                is at or near 100%, when writes are failing with "No space left on device", or \
                when someone asks why a host is out of disk.
                """,
            body: """
                # Disk Full Triage

                Work out *what* grew before proposing to delete anything. A full disk is usually one
                directory, and the fix depends on which.

                ## 1. Find the full filesystem

                ```
                df -h
                df -i
                ```

                Check both. A filesystem at 100% inodes with free bytes is a different problem —
                millions of small files, usually a session or cache directory — and `du` will not
                show it as large.

                ## 2. Find what is using it

                Descend from the mount point that is full, one level at a time:

                ```
                du -x -h -d 1 /var 2>/dev/null | sort -h | tail -20
                ```

                `-x` matters: without it you walk into other filesystems and misattribute their
                size. Repeat into the largest child until a single directory explains the shortfall.

                ## 3. Check for deleted-but-open files

                If `du` totals are far below what `df` reports, something is holding a deleted file
                open — a rotated log a process never reopened:

                ```
                lsof -nP +L1 2>/dev/null | head -40
                ```

                That space returns when the process is restarted, not when the file is removed. Say
                which process, and let the user decide about restarting it.

                ## 4. The usual culprits

                - `journalctl --disk-usage`, capped with `journalctl --vacuum-size=…`
                - `/var/log` with rotation misconfigured, or `*.log.1` never compressed
                - Docker: `docker system df` before `docker system prune`
                - Package caches: `/var/cache/apt`, `/var/cache/yum`
                - A core dump or a database backup somebody left in place

                ## 5. Report before removing

                Say what filled the disk, how much each candidate would return, and what the risk of
                each is. Removing files is the user's decision — propose it and let the approval
                prompt be where it happens. Never `rm -rf` a directory you have not listed first.
                """
        )
    }

    private static var failingService: AgentSkill {
        AgentSkill(
            name: "failing-service-triage",
            title: "Failing Service Triage",
            summary: """
                Diagnose a systemd unit that will not start or keeps restarting. Use when a service \
                is down, flapping, reported as failed or inactive, or when a site or API on a host \
                has stopped responding.
                """,
            body: """
                # Failing Service Triage

                Read the failure before touching the service. A restart that "fixes" it without a
                cause found is the same outage again in an hour.

                ## 1. What the unit says

                ```
                systemctl status <unit> --no-pager -l
                systemctl show <unit> -p Result -p ExecMainStatus -p NRestarts
                ```

                `Result` and the exit status usually name the class of failure on their own:
                `exit-code` is the program's own error, `signal` is a crash or an OOM kill, `timeout`
                is a unit that never signalled readiness.

                ## 2. What the logs say

                ```
                journalctl -u <unit> -n 200 --no-pager
                journalctl -u <unit> --since "1 hour ago" -p err --no-pager
                ```

                Read from the *first* error of the most recent start, not the last line. The last
                line is usually the supervisor giving up; the first is the reason.

                ## 3. Rule out the ordinary causes

                - **Config**: validate before restarting — `nginx -t`, `sshd -t`,
                  `postgres --check`, `caddy validate`. A syntax error found here costs nothing.
                - **Port already bound**: `ss -lntp | grep <port>`
                - **Permissions**: the unit's `User=` against the paths in its `ExecStart=`
                - **Out of memory**: `journalctl -k | grep -i "killed process"`
                - **Dependency**: `systemctl list-dependencies <unit> --failed`
                - **Disk**: a full filesystem breaks services in unrelated-looking ways

                ## 4. Then act

                Say what failed and why, and propose the specific change. A restart is worth
                proposing only once you can say what it will fix; when you cannot, say that instead —
                an unexplained flap is worth more investigation, not a restart loop.
                """
        )
    }

    private static var safeConfigEdit: AgentSkill {
        AgentSkill(
            name: "safe-config-edit",
            title: "Safe Remote Config Edit",
            summary: """
                Change a configuration file on a host without risking a broken service or an \
                unrecoverable state. Use when editing nginx, sshd, systemd units, database or \
                application config on a remote machine.
                """,
            body: """
                # Safe Remote Config Edit

                The order matters more than the edit. Every step below exists because skipping it is
                how a config change becomes an outage you cannot log in to fix.

                ## 1. Pull it, do not read it into the chat

                ```
                scratch_pull    → stage the file locally
                scratch_copy    → keep the pristine copy to diff against
                scratch_replace → change the lines you mean to change
                scratch_push    → send it back
                ```

                The contents never enter the conversation, revisions cost a diff instead of another
                copy of the file, and the only step the user approves is the one that reaches their
                host. Use `scratch_read` on the staged copy when you need to see it, and
                `scratch_diff` against the pristine copy to check what you actually changed.

                ## 2. Keep a way back

                Before pushing, copy the original beside itself:

                ```
                cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak-$(date +%Y%m%d%H%M%S)
                ```

                `-a` preserves owner, group and mode. A backup that root can read and the service
                user cannot is not a backup.

                ## 3. Validate before reloading

                ```
                nginx -t
                sshd -t
                systemd-analyze verify /etc/systemd/system/<unit>.service
                visudo -c -f <file>
                ```

                If the tool has a check mode, it runs before the reload, every time.

                ## 4. Reload rather than restart, where that exists

                `systemctl reload nginx` keeps connections; `restart` drops them. Reload only after
                validation passed.

                ## 5. Never lock yourself out

                Editing `sshd_config`, a firewall, or anything else in the path you are connected
                over: keep the current session open, validate, reload, and prove a *new* connection
                works before closing anything. Say this to the user explicitly — they are the one who
                has to keep the window open.

                ## 6. Say what changed

                Report the diff, the backup path, the validation output, and how to roll back. A
                change nobody can undo in one command is not finished.
                """
        )
    }
}
