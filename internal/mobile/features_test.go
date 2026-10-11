package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// featureClash keeps the controller state independent of the mobile cache. Its
// delay handler runs outside the lock so tests can exercise real overlapping IO.
type featureClash struct {
	mu            sync.Mutex
	mode          string
	proxies       map[string]Proxy
	rules         []Rule
	rulesStatus   int
	putStatus     int
	puts          int
	afterReadback func(*featureClash)
	delayHandler  http.HandlerFunc
}

type featureTransport struct{ handler http.Handler }

func (t featureTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if err := r.Context().Err(); err != nil {
		return nil, err
	}
	w := httptest.NewRecorder()
	t.handler.ServeHTTP(w, r)
	if err := r.Context().Err(); err != nil {
		return nil, err
	}
	return w.Result(), nil
}

func newFeatureServer(t *testing.T) (*Server, *featureClash) {
	t.Helper()
	f := &featureClash{mode: "global", putStatus: 204, proxies: map[string]Proxy{
		"GLOBAL": {Type: "Selector", Now: "first", All: []string{"first", "second"}},
		"auto":   {Type: "URLTest", Now: "first", All: []string{"first", "second"}},
		"first":  {Type: "Shadowsocks"},
		"second": {Type: "Shadowsocks"},
	}}
	upstream := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/proxies/") && strings.HasSuffix(r.URL.Path, "/delay") {
			if f.delayHandler != nil {
				f.delayHandler(w, r)
			} else {
				reply(w, 200, map[string]int{"delay": 25})
			}
			return
		}
		f.mu.Lock()
		defer f.mu.Unlock()
		switch {
		case r.Method == "GET" && r.URL.Path == "/configs":
			reply(w, 200, map[string]string{"mode": f.mode})
		case r.Method == "GET" && r.URL.Path == "/proxies":
			reply(w, 200, map[string]any{"proxies": f.proxies})
		case r.Method == "GET" && r.URL.Path == "/rules":
			if f.rulesStatus != 0 {
				w.WriteHeader(f.rulesStatus)
			} else {
				reply(w, 200, map[string]any{"rules": f.rules})
			}
		case strings.HasPrefix(r.URL.Path, "/proxies/"):
			name := strings.TrimPrefix(r.URL.Path, "/proxies/")
			p, ok := f.proxies[name]
			if !ok {
				w.WriteHeader(404)
				return
			}
			if r.Method == "PUT" {
				var input struct{ Name string }
				if json.NewDecoder(r.Body).Decode(&input) != nil {
					w.WriteHeader(400)
					return
				}
				p.Now = input.Name
				f.proxies[name] = p
				f.puts++
				w.WriteHeader(f.putStatus)
			} else if r.Method == "GET" {
				reply(w, 200, p)
				if f.afterReadback != nil {
					f.afterReadback(f)
				}
			} else {
				w.WriteHeader(405)
			}
		default:
			w.WriteHeader(404)
		}
	})
	cfg := Config{Listen: "127.0.0.1:8787", AllowedClients: []string{"127.0.0.1"}, Token: strings.Repeat("z", 43), Pipe: `\\.\pipe\feature-test`, StateFile: filepath.Join(t.TempDir(), "status.json")}
	s, err := New(cfg, Controller{Client: &http.Client{Transport: featureTransport{handler: upstream}, Timeout: 2 * time.Second}})
	if err != nil {
		t.Fatal(err)
	}
	return s, f
}

func decodedFeatureState(t *testing.T, w *httptest.ResponseRecorder) State {
	t.Helper()
	if w.Code != 200 {
		t.Fatalf("state returned %d: %s", w.Code, w.Body.String())
	}
	var state State
	if err := json.Unmarshal(w.Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	return state
}

func featureGroup(t *testing.T, state State, name string) Group {
	t.Helper()
	for _, group := range state.Groups {
		if group.Name == name {
			return group
		}
	}
	t.Fatalf("group %q was not returned", name)
	return Group{}
}

func TestFeatureRoutingUsesRulesAndNestedSelection(t *testing.T) {
	s, f := newFeatureServer(t)
	f.mode = "rule"
	f.proxies["主选择"] = Proxy{Type: "Selector", Now: "auto", All: []string{"auto", "second"}}
	f.proxies["业务"] = Proxy{Type: "Selector", Now: "second", All: []string{"first", "second"}}
	f.rules = []Rule{{Type: "DOMAIN", Proxy: "业务"}, {Type: "MATCH", Proxy: "主选择"}}
	state := decodedFeatureState(t, call(s, "GET", "/api/state", "", nil))
	if state.PreferredGroup != "主选择" || featureGroup(t, state, "GLOBAL").RoutingUsed {
		t.Fatalf("rule mode picked an unrelated GLOBAL: %+v", state)
	}
	for _, name := range []string{"主选择", "auto", "业务"} {
		if !featureGroup(t, state, name).RoutingUsed {
			t.Fatalf("rule selection chain omitted %q", name)
		}
	}
	if !strings.Contains(featureGroup(t, state, "GLOBAL").RoutingNote, "规则") {
		t.Fatal("unused GLOBAL did not explain rule mode")
	}
	f.mu.Lock()
	f.mode = "global"
	f.proxies["GLOBAL"] = Proxy{Type: "Selector", Now: "主选择", All: []string{"主选择", "first"}}
	f.mu.Unlock()
	state = decodedFeatureState(t, call(s, "GET", "/api/state", "", nil))
	if state.PreferredGroup != "GLOBAL" || !featureGroup(t, state, "主选择").RoutingUsed || !featureGroup(t, state, "auto").RoutingUsed || featureGroup(t, state, "业务").RoutingUsed {
		t.Fatalf("incorrect nested global chain: %+v", state)
	}
}

func TestFeatureDirectAndUnknownRulesDoNotClaimEffectiveRouting(t *testing.T) {
	for _, mode := range []string{"direct", "rule"} {
		t.Run(mode, func(t *testing.T) {
			s, f := newFeatureServer(t)
			f.mode, f.rulesStatus = mode, 503
			state := decodedFeatureState(t, call(s, "GET", "/api/state", "", nil))
			if !state.Online || state.PreferredGroup != "" {
				t.Fatalf("invented a preferred group or outage: %+v", state)
			}
			for _, g := range state.Groups {
				if g.RoutingUsed || g.RoutingNote == "" {
					t.Fatalf("routing was asserted without evidence: %+v", g)
				}
			}
		})
	}
}

func TestFeatureLatencyHistoryAndFixedURLMeasurements(t *testing.T) {
	s, f := newFeatureServer(t)
	name := "香港 / 节点?x=1#片段"
	oldTime := time.Now().Add(-time.Minute).UTC().Truncate(time.Second)
	f.proxies[name] = Proxy{Type: "Shadowsocks", History: []DelayHistory{{Time: oldTime, Delay: 77}}}
	f.proxies["zero"] = Proxy{Type: "Shadowsocks", History: []DelayHistory{{Time: oldTime, Delay: 0}}}
	f.proxies["GLOBAL"] = Proxy{Type: "Selector", Now: name, All: []string{name, "zero", "missing-delay", "broken", "http-error"}}
	initial := decodedFeatureState(t, call(s, "GET", "/api/state", "", nil))
	if initial.Latencies[name].DelayMS != 77 || initial.Latencies[name].TestedAt != oldTime.Format(time.RFC3339Nano) || initial.Latencies["zero"].Status != "timeout" {
		t.Fatalf("controller history not preserved: %+v", initial.Latencies)
	}
	var invalid atomic.Int32
	var escapedNameSeen atomic.Bool
	f.delayHandler = func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.Query().Get("url") != delayURL || r.URL.Query().Get("timeout") != "3000" {
			invalid.Add(1)
		}
		if r.URL.EscapedPath() == "/proxies/"+url.PathEscape(name)+"/delay" {
			escapedNameSeen.Store(true)
		}
		node := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/proxies/"), "/delay")
		switch node {
		case name:
			reply(w, 200, map[string]int{"delay": 42})
		case "zero":
			reply(w, 200, map[string]int{"delay": 0})
		case "missing-delay":
			reply(w, 200, map[string]string{"message": "no measurement"})
		case "broken":
			_, _ = w.Write([]byte(`{"delay":`))
		case "http-error":
			w.WriteHeader(503)
		default:
			invalid.Add(1)
			w.WriteHeader(404)
		}
	}
	state := decodedFeatureState(t, call(s, "POST", "/api/delay", `{"group":"GLOBAL"}`, nil))
	if invalid.Load() != 0 || !escapedNameSeen.Load() {
		t.Fatal("delay escaped name or fixed request URL was incorrect")
	}
	if state.Latencies[name].DelayMS != 42 || state.Latencies[name].Status != "ok" || !newerLatency(state.Latencies[name], initial.Latencies[name]) {
		t.Fatalf("new measurement did not replace older controller history: %+v", state.Latencies[name])
	}
	if state.Latencies["zero"].Status != "timeout" {
		t.Fatal("zero measurement was presented as working 0 ms")
	}
	for _, node := range []string{"missing-delay", "broken", "http-error"} {
		if state.Latencies[node].Status != "error" {
			t.Fatalf("%q failed measurement was presented as usable: %+v", node, state.Latencies[node])
		}
	}
	f.mu.Lock()
	puts, automaticNow := f.puts, f.proxies["auto"].Now
	f.mu.Unlock()
	if puts != 0 || automaticNow != "first" {
		t.Fatal("latency tests changed controller selection")
	}
	// A normal refresh must keep the new cache result instead of regressing to
	// the fixture's older controller history.
	state = decodedFeatureState(t, call(s, "GET", "/api/state", "", nil))
	if state.Latencies[name].DelayMS != 42 {
		t.Fatal("polling replaced measured delay with old history")
	}
}

func TestFeatureDelayRejectsUnknownNodesAndBrowserURLs(t *testing.T) {
	s, f := newFeatureServer(t)
	var calls atomic.Int32
	f.delayHandler = func(w http.ResponseWriter, r *http.Request) { calls.Add(1); reply(w, 200, map[string]int{"delay": 1}) }
	for _, body := range []string{
		`{"group":"missing"}`,
		`{"group":"GLOBAL","names":["unknown"]}`,
		`{"group":"GLOBAL","names":["first"],"url":"http://127.0.0.1/private"}`,
		`{"group":"GLOBAL"}{}`,
	} {
		if w := call(s, "POST", "/api/delay", body, nil); w.Code != 400 {
			t.Fatalf("invalid test accepted: %d %s", w.Code, w.Body.String())
		}
	}
	if calls.Load() != 0 {
		t.Fatal("unvalidated measurement reached the controller")
	}
}

func TestFeatureDelayDoesNotBlockStateOrSelection(t *testing.T) {
	s, f := newFeatureServer(t)
	started, release := make(chan struct{}), make(chan struct{})
	var signal sync.Once
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	t.Cleanup(unblock)
	f.delayHandler = func(w http.ResponseWriter, r *http.Request) {
		signal.Do(func() { close(started) })
		select {
		case <-release:
			reply(w, 200, map[string]int{"delay": 31})
		case <-r.Context().Done():
		}
	}
	delayDone := make(chan *httptest.ResponseRecorder, 1)
	go func() { delayDone <- call(s, "POST", "/api/delay", `{"group":"auto","names":["first"]}`, nil) }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("latency request did not reach controller")
	}
	stateDone := make(chan *httptest.ResponseRecorder, 1)
	go func() { stateDone <- call(s, "GET", "/api/state", "", nil) }()
	select {
	case w := <-stateDone:
		decodedFeatureState(t, w)
	case <-time.After(time.Second):
		t.Fatal("latency held state mutex during measurement")
	}
	selectionDone := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		selectionDone <- call(s, "POST", "/api/select", `{"id":"latency-select-01","group":"GLOBAL","name":"second"}`, nil)
	}()
	select {
	case w := <-selectionDone:
		var event Event
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &event) != nil || event.Status != "success" {
			t.Fatalf("concurrent selection not confirmed: %d %s", w.Code, w.Body.String())
		}
	case <-time.After(time.Second):
		t.Fatal("latency blocked user selection")
	}
	if w := call(s, "POST", "/api/delay", `{"group":"auto"}`, nil); w.Code != 409 {
		t.Fatal("overlapping latency batch was not rejected")
	}
	unblock()
	select {
	case w := <-delayDone:
		state := decodedFeatureState(t, w)
		if featureGroup(t, state, "GLOBAL").Now != "second" || featureGroup(t, state, "auto").Now != "first" {
			t.Fatal("measurement overwrote manual or automatic selection")
		}
	case <-time.After(time.Second):
		t.Fatal("released measurement did not finish")
	}
	if w := call(s, "POST", "/api/delay", `{"group":"auto"}`, nil); w.Code != 429 {
		t.Fatal("immediate repeated batch was not rate limited")
	}
}

func TestFeatureSelectionChecksFinalSnapshotAndFailedPUTReadback(t *testing.T) {
	for _, scenario := range []struct {
		name       string
		putStatus  int
		override   bool
		wantStatus string
		wantNode   string
	}{
		{"final desktop change", 204, true, "unconfirmed", "first"},
		{"PUT error but applied", 503, false, "success", "second"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			s, f := newFeatureServer(t)
			f.putStatus = scenario.putStatus
			if scenario.override {
				f.afterReadback = func(f *featureClash) {
					p := f.proxies["GLOBAL"]
					p.Now = "first"
					f.proxies["GLOBAL"] = p
				}
			}
			body := `{"id":"verify-feature-01","group":"GLOBAL","name":"second"}`
			w := call(s, "POST", "/api/select", body, nil)
			var event Event
			if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &event) != nil || event.Status != scenario.wantStatus || event.Current != scenario.wantNode {
				t.Fatalf("wrong final confirmation: %d %s", w.Code, w.Body.String())
			}
			b, err := os.ReadFile(s.config.StateFile)
			if err != nil {
				t.Fatal(err)
			}
			var desktop State
			if json.Unmarshal(b, &desktop) != nil || len(desktop.Events) != 1 || desktop.Events[0].Status != scenario.wantStatus || featureGroup(t, desktop, "GLOBAL").Now != scenario.wantNode {
				t.Fatalf("desktop received a contradictory confirmation: %s", b)
			}
			w = call(s, "POST", "/api/select", body, nil)
			if w.Code != 200 || f.puts != 1 {
				t.Fatal("retry reapplied a completed command")
			}
		})
	}
}

func TestFeatureCanceledRefreshPreservesHealthySnapshot(t *testing.T) {
	s, _ := newFeatureServer(t)
	if err := s.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	previous := s.state
	previousFile, err := os.ReadFile(s.config.StateFile)
	if err != nil {
		s.mu.Unlock()
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- s.Refresh(ctx) }()
	<-ctx.Done()
	s.mu.Unlock()
	if err := <-done; !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expired refresh should report context timeout, got %v", err)
	}
	s.mu.Lock()
	current := s.state
	s.mu.Unlock()
	currentFile, err := os.ReadFile(s.config.StateFile)
	if err != nil {
		t.Fatal(err)
	}
	if !current.Online || current.Updated != previous.Updated || string(previousFile) != string(currentFile) {
		t.Fatal("expired lock wait published or persisted a false outage")
	}
}
