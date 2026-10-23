# Deterministic pre-tool guard

The optional Claude Code PreToolUse hook checks a tool call **before** the agent executes it. This complements (not replaces) the end-state test/reviewer cycle.

## What it enforces

When enabled, it:

- permits Edit, Write, MultiEdit, and NotebookEdit only for project-relative paths matching the active contract's approved_paths;
- applies forbidden_paths before allowing a write;
- always protects AGENTS.md, .claude/settings.json, .github/workflows/**, and .ai-native/** from these file-edit tools;
- blocks common destructive shell commands such as git reset --hard, forced git clean, force-push, rm -rf, and git checkout -- .;
- fails closed for matched tools if the active contract is missing, invalid, or has no non-empty approved_paths.

## Enable it in a target project

1. Copy scripts/pre_tool_guard.py and merge the PreToolUse entry from .claude/settings.json into the target project's Claude Code settings. If you also want end-state review, copy .claude/hooks/ai-native-stop.py and scripts/ai_native.py; do not overwrite an existing settings file without merging its hooks.
2. Keep the active task contract outside the executor's approved write scope. Add fields like these to the otherwise complete task contract:

        {
          "approved_paths": ["app/**", "tests/**"],
          "forbidden_paths": ["app/src/main/res/values/secrets.xml"]
        }

   Patterns are relative to the target repository. Use explicit paths for each task rather than broad ** access whenever possible.
3. Before launching Claude Code, set the variables to the contract's absolute path.

   **macOS/Linux**

       export AI_NATIVE_GUARD_ENABLED=1
       export AI_NATIVE_CONTRACT_PATH=/absolute/path/to/my-contract.json

   **Windows PowerShell**

       $env:AI_NATIVE_GUARD_ENABLED = '1'
       $env:AI_NATIVE_CONTRACT_PATH = 'C:\absolute\path\to\my-contract.json'

4. Restart Claude Code so it inherits the environment and reloads the hook settings. Test on a disposable branch: an edit inside an approved path should proceed; an edit outside it should be denied with a scope-guard reason. Leave the guard disabled until the contract and hook behavior have been tested.

## Important limitation

This is a deterministic **tool-call policy check**, not a security sandbox. It checks path scope for the listed file-edit tools and blocks a short list of dangerous shell commands; arbitrary shell redirection, scripts, other tools, or a user-approved bypass may evade those checks. For stronger enforcement, use an isolated worktree, the agent client's sandbox/permission controls, a separately read-only reviewer, and required CI/branch protection. The existing end-state controller must still run tests and review fresh evidence; a pre-tool allow decision does not mean the task passed.

The Claude Code hook does not automatically apply to Codex, Cursor, or other agents. Integrate the same policy at their tool boundary or run the shared controller from their supported task-completion hook.
