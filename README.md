Agent in a box. Locks down the network and filesystem so an agent is free to explore the mounted workspace while reducing the risk of it going off the rails. 

## Getting started

### Install

```
git clone https://github.com/noperator/agent-box
```

### Configure

```
docker build -t agent-box .
```

### Usage

```
docker run -it --rm \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    -v "$(pwd):/workspace" \
    -v agent-home:/home/agent \
    agent-box
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
- [ ] git-aware read-only mounts
- [ ] refresh firewall after init
