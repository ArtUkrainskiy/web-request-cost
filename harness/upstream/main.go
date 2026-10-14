// Upstream stand-in for the waiting scenario: GET /wait?ms=N answers {"ok":true} after N ms.
//
//	UPSTREAM_ADDR=127.0.0.1:9090 ./upstream
package main

import (
	"log"
	"net/http"
	"os"
	"strconv"
	"time"
)

func main() {
	http.HandleFunc("GET /wait", func(w http.ResponseWriter, r *http.Request) {
		ms, _ := strconv.Atoi(r.URL.Query().Get("ms"))
		time.Sleep(time.Duration(ms) * time.Millisecond)
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"ok":true}`))
	})
	log.Fatal(http.ListenAndServe(os.Getenv("UPSTREAM_ADDR"), nil))
}
