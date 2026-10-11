package mobile

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const delayURL = "https://www.gstatic.com/generate_204"
const maxDelayNodes = 256
const delayWorkers = 16

type DelayHistory struct {
	Time  time.Time `json:"time"`
	Delay uint32    `json:"delay"`
}
type Latency struct {
	DelayMS  uint32 `json:"delay_ms"`
	Status   string `json:"status"`
	TestedAt string `json:"tested_at"`
}

func newerLatency(a, b Latency) bool {
	at, _ := time.Parse(time.RFC3339Nano, a.TestedAt)
	bt, _ := time.Parse(time.RFC3339Nano, b.TestedAt)
	return at.After(bt)
}

func (s *Server) measureDelay(w http.ResponseWriter, r *http.Request) {
	if strings.Split(r.Header.Get("Content-Type"), ";")[0] != "application/json" {
		http.Error(w, "JSON required", 415)
		return
	}
	var input struct {
		Group string   `json:"group"`
		Names []string `json:"names,omitempty"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 131072))
	dec.DisallowUnknownFields()
	if dec.Decode(&input) != nil || dec.Decode(&struct{}{}) != io.EOF || len(input.Group) > 512 || len(input.Names) > maxDelayNodes {
		http.Error(w, "Invalid request", 400)
		return
	}
	if !s.delayMu.TryLock() {
		reply(w, 409, map[string]string{"error": "A latency test is already running"})
		return
	}
	defer s.delayMu.Unlock()
	if time.Since(s.delayStarted) < 30*time.Second {
		reply(w, 429, map[string]string{"error": "Please wait 30 seconds between latency tests"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 70*time.Second)
	defer cancel()
	s.mu.Lock()
	s.refresh(ctx)
	var names []string
	for _, g := range s.state.Groups {
		if g.Name == input.Group {
			names = append([]string{}, g.All...)
			break
		}
	}
	online := s.state.Online
	s.mu.Unlock()
	if !online || ctx.Err() != nil {
		reply(w, 503, map[string]string{"error": "Clash is unavailable"})
		return
	}
	if len(names) == 0 {
		reply(w, 400, map[string]string{"error": "Choose an existing proxy group"})
		return
	}
	allowed := map[string]bool{}
	for _, name := range names {
		allowed[name] = true
	}
	if len(input.Names) > 0 {
		for _, name := range input.Names {
			if !allowed[name] || len(name) > 512 {
				reply(w, 400, map[string]string{"error": "Choose existing nodes in this group"})
				return
			}
		}
		names = input.Names
	}
	dedup := map[string]bool{}
	unique := []string{}
	for _, name := range names {
		if !dedup[name] {
			unique = append(unique, name)
			dedup[name] = true
		}
	}
	if len(unique) > maxDelayNodes {
		reply(w, 400, map[string]string{"error": "A latency test supports up to 256 nodes"})
		return
	}
	s.delayStarted = time.Now()
	jobs := make(chan string, len(unique))
	for _, name := range unique {
		jobs <- name
	}
	close(jobs)
	var resultMu sync.Mutex
	results := map[string]Latency{}
	var workers sync.WaitGroup
	for i := 0; i < delayWorkers && i < len(unique); i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for name := range jobs {
				nodeCtx, nodeCancel := context.WithTimeout(ctx, 4*time.Second)
				var measured struct {
					Delay *uint32 `json:"delay"`
				}
				path := "/proxies/" + url.PathEscape(name) + "/delay?" + url.Values{"url": {delayURL}, "timeout": {"3000"}}.Encode()
				err := s.controller.request(nodeCtx, "GET", path, nil, &measured)
				status := "error"
				var delay uint32
				if err == nil && measured.Delay != nil {
					delay = *measured.Delay
					status = "ok"
					if delay == 0 {
						status = "timeout"
					}
				} else if nodeCtx.Err() != nil {
					status = "timeout"
				}
				nodeCancel()
				resultMu.Lock()
				results[name] = Latency{DelayMS: delay, Status: status, TestedAt: time.Now().UTC().Format(time.RFC3339Nano)}
				resultMu.Unlock()
			}
		}()
	}
	workers.Wait()
	s.mu.Lock()
	defer s.mu.Unlock()
	// Keep the cache bounded even if the subscription changes repeatedly.
	if len(s.latencies)+len(results) > 2048 {
		s.latencies = map[string]Latency{}
	}
	for name, result := range results {
		s.latencies[name] = result
	}
	if s.state.Latencies == nil {
		s.state.Latencies = map[string]Latency{}
	}
	for name, result := range results {
		s.state.Latencies[name] = result
	}
	s.state.Updated = time.Now().UTC().Format(time.RFC3339Nano)
	if err := s.persist(); err != nil {
		reply(w, 503, map[string]string{"error": "Cannot synchronize desktop state"})
		return
	}
	reply(w, 200, s.state)
}
