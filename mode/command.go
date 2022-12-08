package mode

import (
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
)

type CommandMode struct {
	choices []string
}

func NewCommandMode() CommandMode {
	result := CommandMode{}
	result.choices = searchPath()
	return result
}

func searchOnePath(dirName string, ch chan<- string, done chan<- struct{}) {
	defer func() {
		done <- struct{}{}
	}()

	dir, err := os.ReadDir(dirName)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return
	}
	for _, entry := range dir {
		info, err := entry.Info()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			continue
		}
		stat, err := os.Stat(dirName + "/" + info.Name())
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			continue
		}
		if stat.Mode().Perm() == 0 {
			continue
		}
		ch <- entry.Name()
	}
}

func searchPath() []string {
	path := os.Getenv("PATH")
	names := map[string]struct{}{}
	ch := make(chan string)
	done := make(chan struct{})

	threadsLeft := 0
	for _, dirName := range strings.Split(path, ":") {
		go searchOnePath(dirName, ch, done)
		threadsLeft++
	}

	for threadsLeft > 0 {
		select {
		case <-done:
			threadsLeft--
		case name := <-ch:
			names[name] = struct{}{}
		}
	}

	result := make([]string, len(names))
	index := 0
	for name := range names {
		result[index] = name
		index++
	}

	sort.Strings(result)

	return result
}

func (c *CommandMode) Choices() []string {
	return c.choices
}

func (c *CommandMode) CustomAllowed() bool {
	return true
}

func (c *CommandMode) Execute(choice string) {
	err := exec.Command("sh", "-c", choice).Start()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
}
