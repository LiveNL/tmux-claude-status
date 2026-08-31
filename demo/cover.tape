# vhs demo/cover.tape && python3 demo/cover.py  (run from the repo root)
Output demo/.cover-raw.gif

Set FontSize 21
Set FontFamily "Menlo"
Set Width 1250
Set Height 260
Set Padding 14
Set WindowBar Colorful
Set Theme { "name": "demo", "background": "#0f1c1e", "foreground": "#c9d4d4", "cursor": "#0f1c1e", "black": "#0f1c1e", "red": "#ff5757", "green": "#50c8a0", "yellow": "#ffbf40", "blue": "#4db2d6", "magenta": "#c678dd", "cyan": "#4db2d6", "white": "#d9e0e0", "brightBlack": "#587b7b", "brightRed": "#ff5757", "brightGreen": "#50c8a0", "brightYellow": "#ffbf40", "brightBlue": "#4db2d6", "brightMagenta": "#c678dd", "brightCyan": "#4db2d6", "brightWhite": "#eef2f2" }

Hide
Type "bash demo/drive.sh cover && tmux -L claude-demo attach -t work"
Enter
Sleep 2s
Show
Sleep 1s
Hide
Ctrl+B
Type "d"
Sleep 500ms
Type "bash demo/drive.sh down"
Enter
