# vhs demo/demo.tape  (run from the repo root)
Output screenshots/demo.gif

Set FontSize 17
Set Width 1150
Set Height 340
Set Padding 10
Set Theme "Catppuccin Mocha"

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
