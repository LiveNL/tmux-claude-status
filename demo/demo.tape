# vhs demo/demo.tape  (run from the repo root)
Output screenshots/demo.gif

Set FontSize 21
Set FontFamily "Menlo"
Set Width 1250
Set Height 330
Set Padding 14
Set Theme { "name": "demo", "background": "#0f1c1e", "foreground": "#b8c7c7", "cursor": "#0f1c1e", "black": "#0f1c1e", "red": "#e85c51", "green": "#7aa4a1", "yellow": "#ffcc66", "blue": "#5a93aa", "magenta": "#a8748c", "cyan": "#5a93aa", "white": "#d9e0e0", "brightBlack": "#587b7b", "brightRed": "#e85c51", "brightGreen": "#7aa4a1", "brightYellow": "#ffcc66", "brightBlue": "#5a93aa", "brightMagenta": "#a8748c", "brightCyan": "#5a93aa", "brightWhite": "#eef2f2" }

Hide
Type "bash demo/drive.sh up && tmux -L claude-demo attach -t work"
Enter
Sleep 1s
Show

Sleep 20s

Hide
Ctrl+B
Type "d"
Sleep 500ms
Type "bash demo/drive.sh down"
Enter
