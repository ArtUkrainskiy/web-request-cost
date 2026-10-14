# Blog API server: uvicorn with uvloop and httptools, BLOG_WORKERS processes sharing one socket
# (uvicorn's supervisor + N workers, like Node's cluster primary + N), app.py in each.
#   BLOG_WORKERS=8 BLOG_DRIVER=pg|mysql BLOG_DSN=... BLOG_POOL=3 BLOG_ADDR=127.0.0.1:8096 .venv/bin/python server.py
import os

import uvicorn

if __name__ == "__main__":  # workers are spawned and re-import this module
    host, port = os.environ["BLOG_ADDR"].rsplit(":", 1)
    uvicorn.run(
        "app:app",
        app_dir=os.path.dirname(os.path.abspath(__file__)),
        host=host,
        port=int(port),
        workers=int(os.environ.get("BLOG_WORKERS") or 1),
        loop="uvloop",
        http="httptools",
        lifespan="on",
        access_log=False,
        log_level="warning",
        server_header=False,
    )
