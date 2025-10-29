Agent in a box. Locks down the network and filesystem so an agent is free to explore the mounted workspace while reducing the risk of it going off the rails. 

## Getting started

### Install

```
git clone https://github.com/noperator/agent-box && cd agent-box
docker build -t agent-box .
```

### Configure

Enter the agent's intended workspace on the host, and save a list of patterns that should be excluded from the agent's mounted filesystem.

```
echo '*.bak' > .agentignore
```

### Usage

```
<AGENT-BOX-DIR>/run.sh
```

### Troubleshooting

This project is an experimental work in progress. There are likely more opportunities to lock this down further.

## Back matter

### See also

- https://github.com/RchGrav/claudebox
- https://github.com/anthropics/claude-code/tree/main/.devcontainer
- https://www.anthropic.com/engineering/claude-code-sandboxing

### To-do

- [ ] specify domains at runtime
- [x] git-aware read-only mounts
- [ ] refresh firewall after init
- [ ] quiet down logging a bit
- [ ] make ignore/readonly configurable
