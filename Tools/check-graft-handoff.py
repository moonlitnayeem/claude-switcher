#!/usr/bin/env python3
"""Read AI Switcher's Graft connection without opening Claude. No conversations, account IDs or prompts are printed."""
import argparse
from collections import Counter
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import socket
import subprocess
import tempfile

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)

def identify_accounts(root, candidates, expected):
    # Share the dashboard's identity rules. The helper exchanges metadata over
    # private pipes. The report only includes counts, timestamps and outcomes.
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory() as folder:
        helper = Path(folder) / "check-labels"
        subprocess.run(["swiftc", "-o", str(helper), str(repo / "Sources/Shared/GraftAccountLabels.swift"),
                        str(repo / "Tools/GraftAccountCheck/main.swift")], check=True)
        result = subprocess.run([str(helper)], input=json.dumps({"root": str(root),
                                "candidates": candidates, "expected": expected}), text=True,
                                capture_output=True, check=True)
        aliases = {}
        matches = {} if expected is not None else None
        for member, record in zip(candidates, json.loads(result.stdout)):
            key = record["canonical"]
            aliases[member] = key
            if matches is not None and key != "main":
                matches[key] = record.get("labelMatches")
        return aliases, matches

def summarize(state, settings, since, label_matches=None, aliases=None, identity_available=True):
    aliases = aliases or {}
    def canonical(member):
        return aliases.get(member, member)
    backup_ids = {canonical(key) for key in settings.get("lenders", {}).get("main", [])} - {"main"}
    assignments = settings.get("assignments", {})
    members = {row["id"]: row for row in state.get("members", [])}
    main_limits = members.get("main", {}).get("limits") or {}
    now = (datetime.now(timezone.utc) - APPLE_EPOCH).total_seconds()
    cutoff = (since - APPLE_EPOCH).total_seconds() if since else 0
    full_now = main_limits.get("week", 0) >= 1 and main_limits.get("weekReset", now + 1) > now
    results = Counter()
    matching_results = Counter()
    last_at = None
    for event in state.get("recent", []):
        if event.get("from") != "main" or event.get("model") != "claude-fable-5-2" or event.get("at", 0) <= cutoff:
            continue
        last_at = max(last_at or 0, event["at"])
        if not 200 <= event.get("status", 0) < 300:
            results["provider_error"] += 1
            continue
        served_by = canonical(event.get("servedBy"))
        if served_by not in backup_ids:
            results["answered_by_main_or_previously_configured_account"] += 1
            continue
        if not identity_available:
            results["answered_by_configured_entry_with_unverified_identity"] += 1
            continue
        session = event.get("session")
        if not session:
            reason = "backup_answer_without_session_attribution"
        elif saved := assignments.get(session):
            if canonical(saved.get("to")) == served_by and saved.get("at", 0) <= event["at"]:
                reason = "backup_answer_with_saved_chat_choice"
            else:
                reason = "backup_answer_with_changed_chat_choice"
        elif any(canonical(entry.get("id")) == "main" and entry.get("reason") == "full" for entry in event.get("passedOver", [])):
            reason = "backup_answer_after_observed_primary_limit"
        elif full_now:
            reason = "backup_answer_without_saved_choice_while_main_reports_full"
        else:
            reason = "backup_answer_without_observed_limit"
        results[reason] += 1
        if label_matches and label_matches.get(served_by) is True:
            matching_results[reason] += 1
    reset = main_limits.get("weekReset")
    report = {"connected": True, "routing_enabled": bool(state.get("configured") and state.get("enabled")),
            "main_weekly_limit_currently_reached": full_now,
            "main_weekly_reset": (APPLE_EPOCH + timedelta(seconds=reset)).astimezone().isoformat(timespec="seconds") if reset else None,
            "configured_backup_count": len(backup_ids) if identity_available else None, "Fable_5_2_results": dict(results),
            "last_observed_Fable": (APPLE_EPOCH + timedelta(seconds=last_at)).astimezone().isoformat(timespec="seconds") if last_at else None}

    if not identity_available:
        report["account_identity_check"] = "Install the Swift compiler to check distinct accounts."
    if label_matches is not None:
        report["expected_account_is_a_configured_backup"] = any(value is True for value in label_matches.values())
        report["all_backup_labels_available"] = all(value is not None for value in label_matches.values())
        report["expected_account_Fable_5_2_answers"] = dict(matching_results)
    return report

def main():
    parser = argparse.ArgumentParser(description=__doc__ + " Account identity checks use the Swift compiler.")
    parser.add_argument("--since", help="Show only routing results after this ISO 8601 time, including its time-zone offset.")
    parser.add_argument("--expected-email", help="Check the named backup against Graft's local account labels. Requires Swift. Output contains only counts and yes/no flags.")
    args = parser.parse_args()
    try:
        since = datetime.fromisoformat(args.since) if args.since else None
        if since is not None and since.tzinfo is None:
            parser.error("--since requires an explicit time-zone offset")
    except ValueError:
        parser.error("--since requires an ISO 8601 timestamp")
    root = Path.home() / "Library/Application Support/ClaudeGraft"
    try:
        with (root / "usage-sharing.json").open() as file:
            settings = json.load(file)
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(2)
            client.connect(str(root / "pool/relay.sock"))
            client.sendall(b"{}\n")
            with client.makefile("rb") as reader:
                state = json.loads(reader.readline(8 * 1024 * 1024))
        candidates = settings.get("lenders", {}).get("main", [])
        try:
            aliases, matches = identify_accounts(root, candidates, args.expected_email.strip() if args.expected_email else None)
        except (FileNotFoundError, subprocess.CalledProcessError):
            if args.expected_email:
                raise SystemExit("Could not verify the expected account using the Swift compiler.")
            report = summarize(state, settings, since, identity_available=False)
        else:
            report = summarize(state, settings, since, matches, aliases)
        print(json.dumps(report, indent=2))
    except (OSError, ValueError):
        raise SystemExit("Graft did not return readable settings and status.")

if __name__ == "__main__":
    main()
