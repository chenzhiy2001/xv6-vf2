echo openocd with config file $1 

# Create a new session named "newsess", split panes and change directory in each
tmux new-session -d -s newsess
tmux send-keys -t newsess "openocd -f $1" Enter
tmux split-window -h -t newsess
tmux send-keys -t newsess "telnet localhost 4444" Enter
tmux split-window -h -t newsess
tmux send-keys -t newsess "sudo minicom -D /dev/ttyACM0 -b 115200" Enter
tmux attach -t newsess