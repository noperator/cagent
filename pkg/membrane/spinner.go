package membrane

import (
	"fmt"
	"os"
	"time"
)

type spinner struct {
	frames []string
	stop   chan struct{}
	done   chan struct{}
}

func newSpinner() *spinner {
	type pos struct {
		cell, dot int
	}

	dotBit := [9]int{0, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80}

	// 2 braille cells = 4x4 dot grid
	// Perimeter path clockwise starting from top-left (L.1):
	//
	//   L.1  L.4  R.1  R.4
	//   L.2  L.5  R.2  R.5
	//   L.3  L.6  R.3  R.6
	//   L.7  L.8  R.7  R.8
	path := []pos{
		{0, 1}, // L.1 top-left
		{0, 4}, // L.4 top, going right
		{1, 1}, // R.1
		{1, 4}, // R.4 top-right
		{1, 5}, // R.5 right side down
		{1, 6}, // R.6
		{1, 8}, // R.8 bottom-right
		{1, 7}, // R.7 bottom, going left
		{0, 8}, // L.8
		{0, 7}, // L.7 bottom-left
		{0, 3}, // L.3 left side up
		{0, 2}, // L.2
	}

	pathLen := len(path)

	render := func(dots []pos) string {
		cells := [2]int{0, 0}
		for _, p := range dots {
			cells[p.cell] |= dotBit[p.dot]
		}
		return string(rune(0x2800+cells[0])) + string(rune(0x2800+cells[1]))
	}

	var frames []string
	// Phase 1: grow from 1 dot to 12 (full box)
	for i := 0; i < pathLen; i++ {
		frames = append(frames, render(path[:i+1]))
	}
	// Phase 2: shrink from 11 dots to 0
	for i := 0; i < pathLen; i++ {
		frames = append(frames, render(path[i+1:]))
	}

	return &spinner{frames: frames}
}

func (s *spinner) Start(label string) {
	s.stop = make(chan struct{})
	s.done = make(chan struct{})

	fmt.Fprintf(os.Stderr, "\033[?25l%s %s", s.frames[0], label)

	go func() {
		defer close(s.done)
		ticker := time.NewTicker(80 * time.Millisecond)
		defer ticker.Stop()
		n := 1
		for {
			select {
			case <-s.stop:
				return
			case <-ticker.C:
				fmt.Fprintf(os.Stderr, "\r%s %s", s.frames[n%len(s.frames)], label)
				n++
			}
		}
	}()
}

func (s *spinner) Stop() {
	if s.stop == nil {
		return
	}
	close(s.stop)
	<-s.done
	fmt.Fprint(os.Stderr, "\r\033[2K\033[?25h")
}
