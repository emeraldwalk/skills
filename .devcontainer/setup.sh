sudo chown -R vscode:vscode /home/vscode/.claude

curl -fsSL https://claude.ai/install.sh | bash

# Add run_task_loop shell function to bashrc
echo 'run_task_loop() { bash /workspaces/skills/.claude/skills/task-tracking/scripts/run_task_loop.sh "$@"; }' >> /home/vscode/.bashrc