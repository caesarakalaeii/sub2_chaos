// Package overlay serves the OBS browser-source overlay: a local HTTP server
// that pushes live vote state to the page over Server-Sent Events (SSE). This
// is the ONLY reactive UI — nothing is drawn in-game.
package overlay

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/bridge"
)

//go:embed web
var webFS embed.FS

// Server is the overlay HTTP server with an SSE fan-out.
type Server struct {
	addr string

	mu      sync.Mutex
	latest  []byte
	clients map[chan []byte]struct{}
}

// New creates an overlay server bound to bind:port (e.g. "127.0.0.1", 8777).
func New(bind string, port int) *Server {
	return &Server{
		addr:    net.JoinHostPort(bind, fmt.Sprintf("%d", port)),
		clients: make(map[chan []byte]struct{}),
	}
}

// Addr returns the listen address.
func (s *Server) Addr() string { return s.addr }

// Broadcast publishes a state snapshot to every connected overlay client and
// stores it as the latest (sent immediately to new clients on connect).
func (s *Server) Broadcast(st bridge.State) {
	data, err := json.Marshal(st)
	if err != nil {
		return
	}
	s.mu.Lock()
	s.latest = data
	for ch := range s.clients {
		select {
		case ch <- data:
		default: // drop for a slow client rather than block the machine
		}
	}
	s.mu.Unlock()
}

func (s *Server) subscribe() chan []byte {
	ch := make(chan []byte, 8)
	s.mu.Lock()
	s.clients[ch] = struct{}{}
	last := s.latest
	s.mu.Unlock()
	if last != nil {
		ch <- last
	}
	return ch
}

func (s *Server) unsubscribe(ch chan []byte) {
	s.mu.Lock()
	delete(s.clients, ch)
	s.mu.Unlock()
}

// Handler builds the HTTP routes (exposed for tests).
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	sub, _ := fs.Sub(webFS, "web")
	fileServer := http.FileServer(http.FS(sub))

	serveIndex := func(w http.ResponseWriter, r *http.Request) {
		b, err := fs.ReadFile(sub, "index.html")
		if err != nil {
			http.Error(w, "overlay page missing", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(b)
	}

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/events", s.handleEvents)
	mux.HandleFunc("/overlay", serveIndex)
	mux.HandleFunc("/overlay/", serveIndex)
	mux.Handle("/", fileServer)
	return mux
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	ch := s.subscribe()
	defer s.unsubscribe(ch)

	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case b := <-ch:
			_, _ = fmt.Fprintf(w, "data: %s\n\n", b)
			flusher.Flush()
		case <-heartbeat.C:
			_, _ = fmt.Fprint(w, ": ping\n\n")
			flusher.Flush()
		}
	}
}

// Run starts the server and blocks until ctx is cancelled, then shuts it down.
func (s *Server) Run(ctx context.Context) error {
	srv := &http.Server{Addr: s.addr, Handler: s.Handler()}
	errc := make(chan error, 1)
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errc <- err
		}
	}()
	select {
	case <-ctx.Done():
		shutCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		return srv.Shutdown(shutCtx)
	case err := <-errc:
		return err
	}
}
