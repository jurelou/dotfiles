diff --git a/examples/config.hcl b/examples/config.hcl
index f1487a1..cb60a22 100644
--- a/examples/config.hcl
+++ b/examples/config.hcl
@@ -18,11 +18,12 @@ pipeline "reports" {
   }
 
   job "info" {
-    plugin = "exec"
+    plugin  = "exec"
+    timeout = 60   # seconds, for the whole job: a job has no other timeout
     params = {
       # The path is passed as $1, never pasted into the script: any file name is safe.
+      # stdout, stderr and rc stored in data.info
       scripts = [["sh", "-c", "printf '%s bytes, sha256 %s' \"$(stat -c %s \"$1\")\" \"$(sha256sum \"$1\" | cut -d ' ' -f 1)\"", "sh", "{{ file }}"]]
-      timeout = 60   # stdout, stderr and rc stored in data.info
     }
   }
 
diff --git a/examples/exec.hcl b/examples/exec.hcl
index 97b4d58..a70e126 100644
--- a/examples/exec.hcl
+++ b/examples/exec.hcl
@@ -5,6 +5,12 @@ scheduler {
 
 pipeline "decrypt" {
   # /mnt/<operation>/<id>/<time>/<file>.bin: decrypted with the secret and the id file of the operation.
+  vars = {   # computed before each job that uses them
+    output = "/data/decrypted/{{ origin_relpath | dirname }}"   # <operation>/<id>/<time>
+    secret = "/home/{{ operation }}.secret"
+    op_id  = "{{ ('/tmp/' ~ operation ~ '/idfile.txt') | file_read | trim }}"
+  }
+
   watch {
     plugin   = "filesystem"
     interval = 60
@@ -16,22 +22,16 @@ pipeline "decrypt" {
   }
 
   job "parse" {
-    plugin = "exec"
+    plugin  = "exec"
+    timeout = 3600   # the whole job: beyond, its script is stopped, the next one is not tried
     params = {
-      dest    = "/data/decrypted/{{ origin_relpath | dirname }}"   # <operation>/<id>/<time>, made before the scripts run
+      dest    = "{{ output }}"   # made before the scripts run
       scripts = [   # in order, until one succeeds
-        ["/opt/1.2.3/venv/bin/prog",
-         "--input", "{{ file }}",
-         "--output", "{{ dest }}",
-         "--secret", "/home/{{ operation }}.secret",
-         "--id", "{{ ('/tmp/' ~ operation ~ '/idfile.txt') | file_read | trim }}"],
-        ["/opt/1.2.4/venv/bin/prog", "decrypt",
-         "--input", "{{ file }}",
-         "--output", "{{ dest }}",
-         "--secret", "/home/{{ operation }}.secret",
-         "--id", "{{ ('/tmp/' ~ operation ~ '/idfile.txt') | file_read | trim }}"],
+        ["/opt/1.2.3/venv/bin/prog", "--input", "{{ file }}", "--output", "{{ dest }}",
+         "--secret", "{{ secret }}", "--id", "{{ op_id }}"],
+        ["/opt/1.2.4/venv/bin/prog", "decrypt", "--input", "{{ file }}", "--output", "{{ dest }}",
+         "--secret", "{{ secret }}", "--id", "{{ op_id }}"],
       ]
-      timeout = 3600
     }
   }
 
diff --git a/examples/full.hcl b/examples/full.hcl
index 917a445..ed79828 100644
--- a/examples/full.hcl
+++ b/examples/full.hcl
@@ -23,16 +23,17 @@ pipeline "invoices" {
   }
 
   job "validate" {
-    plugin = "exec"
-    params = {
+    plugin  = "exec"
+    timeout = 120   # seconds, for the whole job, whatever its plugin
+    params = {   # stdout, stderr and rc stored in data.validate
       scripts = [["/opt/roger/scripts/validate.sh", "--client", "{{ client }}", "{{ file }}"]]
-      timeout = 120   # stdout, stderr and rc stored in data.validate
     }
   }
 
   job "export" {
-    plugin = "copy"
-    params = { dest = "/data/export/{{ client }}/{{ date }}" }
+    plugin  = "copy"
+    timeout = 600   # the whole job: a share that no longer answers fails it after 10 minutes
+    params  = { dest = "/data/export/{{ client }}/{{ date }}" }
   }
 
   job "notify" {
@@ -76,11 +77,12 @@ pipeline "reports" {
   }
 
   job "info" {
-    plugin = "exec"
+    plugin  = "exec"
+    timeout = 60
     params = {
       # The path is passed as $1, never pasted into the script: any file name is safe.
+      # stdout, stderr and rc stored in data.info
       scripts = [["sh", "-c", "printf '%s bytes, sha256 %s' \"$(stat -c %s \"$1\")\" \"$(sha256sum \"$1\" | cut -d ' ' -f 1)\"", "sh", "{{ file }}"]]
-      timeout = 60   # stdout, stderr and rc stored in data.info
     }
   }
 
@@ -115,11 +117,9 @@ pipeline "cleanup" {
   }
 
   job "purge" {
-    plugin = "exec"
-    params = {
-      scripts = [["find", "/srv/exports", "-type", "f", "-mtime", "+30", "-delete"]]
-      timeout = 600
-    }
+    plugin  = "exec"
+    timeout = 600
+    params  = { scripts = [["find", "/srv/exports", "-type", "f", "-mtime", "+30", "-delete"]] }
   }
 
   on_failure {
@@ -172,7 +172,7 @@ pipeline "archives" {
 
   job "publish" {
     plugin = "copy"
-    params = { dest = "/data/unpacked" }
+    params = { dest = "/data/unpacked/{{ file | name }}" }   # the content of the directory goes there
   }
 
   on_failure {
@@ -286,7 +286,15 @@ pipeline "logs" {
 }
 
 pipeline "documents" {
-  # Encrypted documents of an operation: acme_2026-10.enc is parsed with the files of acme.
+  # Encrypted documents of an operation: acme_2026-10.enc is parsed with the key of acme, by the
+  # parser of the version of its format.
+  vars = {   # computed before each job that uses them, with the variables of that moment
+    key_file = "/etc/roger/keys/{{ operation }}.key"   # operation: a group of the regex of the watcher
+    key      = "{{ (key_file if key_file is file else '/etc/roger/keys/default.key') | file_read | trim }}"
+    parser   = "/opt/roger/parsers/{{ data.detect.stdout }}/bin/parse"   # given by the job detect:
+    script   = "{{ parser if parser is file else '/opt/roger/parsers/latest/bin/parse' }}"   # after it only
+  }
+
   watch {
     plugin   = "filesystem"
     interval = 60
@@ -296,23 +304,25 @@ pipeline "documents" {
     }
   }
 
+  job "detect" {   # prints the version of the format of the document: 2.1, for example
+    plugin = "exec"
+    params = { scripts = [["/opt/roger/parsers/detect", "{{ file }}"]] }
+  }
+
   job "parse" {
     plugin = "exec"
     params = {
       dest    = "{{ operation }}"   # in the work directory: a new one for each run
       scripts = [   # in order, until one succeeds
-        ["/opt/roger/parsers/venv/bin/script.py", "{{ file }}",
-         "--id", "{{ ('/tmp/' ~ operation ~ '.key') | file_read | trim }}",
-         "--output", "{{ dest }}",
-         "--secret", "/etc/roger/secrets/{{ operation }}.txt"],
-        ["/opt/roger/parsers/venv/bin/script_v2.py", "{{ file }}", "--output", "{{ dest }}"],
+        ["{{ script }}", "{{ file }}", "--key", "{{ key }}", "--output", "{{ dest }}"],
+        ["/opt/roger/parsers/legacy/bin/parse", "{{ file }}", "--output", "{{ dest }}"],
       ]
     }
   }
 
   job "export" {
     plugin = "copy"
-    params = { dest = "/data/export" }   # the output directory, with all it holds
+    params = { dest = "/data/export/{{ operation }}" }   # what the script wrote, with its tree
   }
 
   on_failure {
@@ -342,11 +352,9 @@ pipeline "remote-jobs" {
   }
 
   job "run" {
-    plugin = "exec"
-    params = {
-      scripts = [["/opt/roger/scripts/job.sh", "{{ id }}", "{{ data.item.spec.target }}"]]
-      timeout = 1800
-    }
+    plugin  = "exec"
+    timeout = 1800
+    params  = { scripts = [["/opt/roger/scripts/job.sh", "{{ id }}", "{{ data.item.spec.target }}"]] }
   }
 
   on_failure {   # data.failure.job: the job, watch (the ack failed) or poll (the API fails)
@@ -364,8 +372,9 @@ pipeline "batches" {
   # Each /data/batches/<batch>/ directory, once its content no longer changes. A batch that gets
   # another file later is processed again, with all its files.
   watch {
-    plugin   = "filesystem"
-    interval = 60
+    plugin       = "filesystem"
+    interval     = 60
+    poll_timeout = 1800   # each poll reads the whole trees: 30 minutes before it counts as blocked
     params = {
       paths    = ["/data/batches"]
       type       = "d"                       # directories: ready once their whole tree is stable
@@ -375,11 +384,9 @@ pipeline "batches" {
   }
 
   job "load" {
-    plugin = "exec"
-    params = {
-      scripts = [["/opt/roger/scripts/load.sh", "{{ batch }}", "{{ file }}"]]
-      timeout = 3600
-    }
+    plugin  = "exec"
+    timeout = 3600
+    params  = { scripts = [["/opt/roger/scripts/load.sh", "{{ batch }}", "{{ file }}"]] }
   }
 
   on_failure {
diff --git a/src/roger/engine/config.py b/src/roger/engine/config.py
index 77627c8..5115db9 100644
--- a/src/roger/engine/config.py
+++ b/src/roger/engine/config.py
@@ -14,6 +14,7 @@ from roger.engine.models import (
     Duration,
     RogerError,
     StrictModel,
+    Timeout,
     check_reserved,
     duplicates,
 )
@@ -52,12 +53,14 @@ class WatchConfig(StrictModel):
     start_mode: Literal["all", "new"] = "new"  # all: also the events there at startup
     alert_every: Duration = 3600  # at most one on_failure run per period for a failing poll
     workers: int = Field(default=1, ge=1)  # how many runs of a poll at the same time
+    poll_timeout: Timeout = 600  # beyond, a poll still running fails
 
 
 class JobConfig(StrictModel):
     name: str
     plugin: str
     when: str = "true"  # a template: the job is skipped when it gives false or nothing
+    timeout: Timeout | None = None  # of the whole job, the only one: the plugins have none
     params: dict[str, Any] = {}
 
     @model_validator(mode="after")
@@ -68,12 +71,13 @@ class JobConfig(StrictModel):
 
 class PipelineConfig(StrictModel):
     name: str = Field(min_length=1)
+    vars: dict[str, str] = {}  # templates, computed before each job that uses them
     watch: WatchConfig
     jobs: dict[str, JobConfig] = Field(min_length=1)
     on_failure: dict[str, JobConfig] = {}
 
-    def variables(self) -> dict[str, str]:
-        """The variables of the runs, with what they hold: roger's, then the watcher's."""
+    def _base_variables(self) -> dict[str, str]:
+        """roger's variables, then the watcher's, with what they hold."""
         watch = self.watch
         watcher = _validated(
             WATCHERS, "watcher", watch.plugin, pipeline_name=self.name, params=watch.params
@@ -82,12 +86,36 @@ class PipelineConfig(StrictModel):
         check_reserved("variable of the watcher", provided, {**RUN_VARS, **NAMESPACES})
         return {**RUN_VARS, **provided}
 
+    def variables(self) -> dict[str, str]:
+        """The variables of the runs, with what they hold: roger's, the watcher's, the vars."""
+        return {**self._base_variables(), **{name: f"var: {v}" for name, v in self.vars.items()}}
+
+    def vars_used(self, value: Any) -> dict[str, str]:
+        """The vars that value uses, with the vars they use in turn, in their order."""
+        needed = template.variables(value) & self.vars.keys()
+        for name in reversed(self.vars):  # a var only uses the vars written before it
+            if name in needed:
+                needed |= template.variables(self.vars[name]) & self.vars.keys()
+        return {name: text for name, text in self.vars.items() if name in needed}
+
+    def _check_vars(self) -> None:
+        base = self._base_variables()
+        if bad := [name for name in self.vars if not template.is_name(name)]:
+            raise ValueError(f'var "{bad[0]}": not a name that a template can use')
+        check_reserved("var", self.vars, {**base, **NAMESPACES})
+        if unknown := sorted(template.unknown_variables(self.vars, base.keys())):
+            raise ValueError(
+                f"vars: unknown variable(s) {', '.join(unknown)}; available: "
+                f"{', '.join(base)}, data.*, env.* and the vars written before"
+            )
+
     @model_validator(mode="after")
     def _check(self) -> Self:
         names = [*self.jobs, *self.on_failure]
         if same := duplicates(names):
             raise ValueError(f"duplicate job names: {', '.join(same)}")
         check_reserved("job name", names, RESERVED_JOBS)
+        self._check_vars()
         variables = self.variables()
         known, available = variables.keys(), ", ".join(variables)
         for job in [*self.jobs.values(), *self.on_failure.values()]:
diff --git a/src/roger/engine/engine.py b/src/roger/engine/engine.py
index 069cfe5..ac13dc2 100644
--- a/src/roger/engine/engine.py
+++ b/src/roger/engine/engine.py
@@ -86,9 +86,9 @@ class Engine:
         loop = asyncio.get_running_loop()
         for sig in (signal.SIGINT, signal.SIGTERM):
             loop.add_signal_handler(sig, self._stop, sig)
-        # the polls and the copies run in threads: at least one per pipeline and per worker
-        threads = len(self._pipelines) + sum(p.config.watch.workers for p in self._pipelines)
-        loop.set_default_executor(ThreadPoolExecutor(max(32, threads)))
+        # the copies of the runs go to threads, at least one per worker; the polls have their own
+        workers = sum(p.config.watch.workers for p in self._pipelines)
+        loop.set_default_executor(ThreadPoolExecutor(max(32, workers)))
 
     async def run_forever(self) -> None:
         self._prepare_loop()
diff --git a/src/roger/engine/filesystem.py b/src/roger/engine/filesystem.py
index 1aa7e51..0ab059e 100644
--- a/src/roger/engine/filesystem.py
+++ b/src/roger/engine/filesystem.py
@@ -3,6 +3,7 @@ import os
 import stat
 import threading
 from collections.abc import Callable, Iterator, Sequence
+from contextlib import suppress
 from pathlib import Path
 from typing import Annotated, Literal, NamedTuple
 
@@ -115,9 +116,10 @@ def _reraise(error: OSError) -> None:
 
 
 def walk_tree(root: Path) -> Iterator[Path]:
-    """root, then all it holds, sorted, the links left out; an unreadable directory raises."""
-    if root.is_symlink():
-        return
+    """root, then all it holds, sorted, the links left out. root missing or a link raises, as an
+    unreadable directory: a copy fails rather than copy nothing."""
+    if stat.S_ISLNK(root.lstat().st_mode):
+        raise ValueError(f"{root} is a symbolic link: links are not followed")
     yield root
     if not root.is_dir():
         return
@@ -141,25 +143,43 @@ def directory_version(directory: str, stopping: threading.Event | None = None) -
     return Version(size, mtime, files)
 
 
+def _copy_file(
+    path: Path, target: Path, copy_file: Callable[[Path, Path], object], ctx: Context
+) -> None:
+    """Copies under a temporary name, then renames: target is never seen half written."""
+    partial = target.with_name(f".roger-{ctx.run_id}.partial")  # short: a long name still fits
+    try:
+        copy_file(path, partial)
+    except BaseException:
+        with suppress(OSError):
+            partial.unlink(missing_ok=True)
+        raise
+    partial.replace(target)
+
+
 def _copy_all(
-    source: Path, dest: Path, copy_file: Callable[[Path, Path], object], ctx: Context
+    source: Path, base: Path, dest: Path, copy_file: Callable[[Path, Path], object], ctx: Context
 ) -> None:
     for path in walk_tree(source):
-        target = dest / path.relative_to(source.parent)
+        target = dest / path.relative_to(base)
         if path.is_dir():
             target.mkdir(parents=True, exist_ok=True)
             continue
         target.parent.mkdir(parents=True, exist_ok=True)
-        copy_file(path, target)
+        _copy_file(path, target, copy_file, ctx)
         ctx.log.debug(f"{path} -> {target}")
 
 
 async def copy_tree(
     source: Path, ctx: Context, dest: str, copy_file: Callable[[Path, Path], object]
 ) -> Path:
-    """Copies source, a file or a directory with its tree, into dest, with copy_file per file."""
+    """Copies source into dest, with copy_file per file: a file goes into dest, a directory gives
+    its content (its whole tree), as `rsync -r source/ dest/`. Returns the copy of source."""
     root = ctx.path(dest)
-    if source.is_dir() and root.resolve().is_relative_to(source.resolve()):
+    if not source.is_dir():
+        await asyncio.to_thread(_copy_all, source, source.parent, root, copy_file, ctx)
+        return root / source.name
+    if root.resolve().is_relative_to(source.resolve()):
         raise ValueError(f"{root} is inside {source}")
-    await asyncio.to_thread(_copy_all, source, root, copy_file, ctx)
-    return root / source.name
+    await asyncio.to_thread(_copy_all, source, source, root, copy_file, ctx)
+    return root
diff --git a/src/roger/engine/models.py b/src/roger/engine/models.py
index 0981c48..2ab5947 100644
--- a/src/roger/engine/models.py
+++ b/src/roger/engine/models.py
@@ -38,6 +38,7 @@ RESERVED_JOBS = {
 }
 
 Duration = Annotated[float, Field(ge=0)]
+Timeout = Annotated[float, Field(gt=0)]  # 0 would fail everything at once
 
 
 def _absolute(path: Path) -> Path:
diff --git a/src/roger/engine/pipeline.py b/src/roger/engine/pipeline.py
index ed3cfb2..67dd54d 100644
--- a/src/roger/engine/pipeline.py
+++ b/src/roger/engine/pipeline.py
@@ -27,6 +27,8 @@ class Pipeline:
         self._alerted = -math.inf
         self._seen: set[str] = set()
         self._ignoring = False  # start_mode new: the first poll that works only ignores
+        self._polling: asyncio.Task[list[Event]] | None = None  # the poll running, maybe blocked
+        self._poll_started = 0.0
 
     async def _poll_failed(self, error: str) -> list[Status]:
         if error == self._error:
@@ -41,7 +43,7 @@ class Pipeline:
         self._alerted = now
         return [await Run(self, Event.poll_failure(error, self.watcher.variables())).execute()]
 
-    async def _poll(self) -> list[Event]:
+    async def _poll_watcher(self) -> list[Event]:
         if not self._ignoring:
             return await self.watcher.poll()
         existing = await self.watcher.existing()
@@ -50,6 +52,29 @@ class Pipeline:
         self.log.info(f"start_mode new: {len(existing)} existing event(s) ignored")
         return []
 
+    async def _poll(self) -> list[Event]:
+        """The events of the poll running, else of a new one. A poll still running after
+        poll_timeout fails (a share that no longer answers), and no other starts until it ends."""
+        if self._polling is None:
+            self._polling = asyncio.create_task(self._poll_watcher())
+            self._poll_started = time.monotonic()
+        polling, limit = self._polling, self.config.watch.poll_timeout
+        stopping = asyncio.create_task(self._stopping.wait())
+        try:
+            left = self._poll_started + limit - time.monotonic()
+            await asyncio.wait(
+                [polling, stopping], timeout=max(left, 0), return_when=asyncio.FIRST_COMPLETED
+            )
+        finally:
+            stopping.cancel()
+        if polling.done():
+            self._polling = None
+            return polling.result()
+        if self._stopping.is_set():
+            polling.cancel()  # left behind: its thread ends on its own, roger does not wait for it
+            raise InterruptedError("stop requested")
+        raise TimeoutError(f"still running after {limit:g} s: no other poll until it ends")
+
     async def _run_events(self, events: list[Event]) -> list[Status]:
         slots = asyncio.Semaphore(self.config.watch.workers)
 
@@ -83,7 +108,6 @@ class Pipeline:
             self.log.debug(f"on_failure: {', '.join(self.config.on_failure)}")
 
     async def cycle(self) -> list[Status]:
-        started = time.monotonic()
         try:
             polled = await self._poll()
         except Exception as exc:
@@ -94,7 +118,7 @@ class Pipeline:
             self.log.info("poll works again")
             self._error = None
         new = list({event.key: event for event in polled if event.key not in self._seen}.values())
-        waiting, duration = self.watcher.waiting, time.monotonic() - started
+        waiting, duration = self.watcher.waiting, time.monotonic() - self._poll_started
         self.log.debug(f"poll: {len(new)} new, {waiting} waiting ({duration:.2f} s)")
         return await self._run_events(new)
 
diff --git a/src/roger/engine/runner.py b/src/roger/engine/runner.py
index 67be9e9..1c48b62 100644
--- a/src/roger/engine/runner.py
+++ b/src/roger/engine/runner.py
@@ -1,7 +1,7 @@
 import asyncio
 import shutil
 import time
-from typing import TYPE_CHECKING
+from typing import TYPE_CHECKING, Any
 
 from pydantic import JsonValue
 
@@ -17,6 +17,7 @@ from roger.engine.models import (
     Status,
     error_text,
 )
+from roger.engine.plugin import Plugin
 from roger.logs import log
 from roger.plugins import PLUGINS
 
@@ -78,19 +79,37 @@ class Run:
                 ctx.log.opt(exception=True).debug("traceback of the hook failure")
                 item = self._with_jobs(item)
 
+    def _variables(self, value: Any, item: Item, ctx: Context) -> dict[str, str]:
+        """The variables of the run, with the vars that value uses, computed now: as if their
+        templates were written in value."""
+        variables = item.template_vars
+        for name, text in self.config.vars_used(value).items():
+            try:
+                variables = {**variables, name: template.render(text, variables, item.data)}
+            except Exception as exc:
+                raise ValueError(f"var {name}: {error_text(exc)}") from exc
+            ctx.log.debug(f"var {name} = {variables[name]}")
+        return variables
+
     async def _job(self, job: JobConfig, item: Item, ctx: Context) -> Item:
-        when = template.render(job.when, item.template_vars, item.data).strip()
+        try:
+            when = template.render(job.when, self._variables(job.when, item, ctx), item.data)
+        except Exception:
+            self.jobs[job.name] = {"status": str(Status.FAILED), "duration": 0.0}
+            raise
+        when = when.strip()
         if when in ("", "false"):
             ctx.log.info(f"skipped: when gives {when or 'nothing'}")
             self.jobs[job.name] = {"status": "skipped", "duration": 0.0}
             return self._with_jobs(item)
         started, status = time.monotonic(), Status.FAILED
         try:
-            rendered = template.render_params(job.params, item.template_vars, item.data)
+            variables = self._variables(job.params, item, ctx)
+            rendered = template.render_params(job.params, variables, item.data)
             plugin = PLUGINS[job.plugin](params=rendered)
             params = plugin.params.model_dump(mode="json", exclude_defaults=True)
             ctx.log.debug(f"{job.plugin} with {params}")
-            result = await plugin.run(item, ctx)
+            result = await self._run_plugin(plugin, item, ctx, job.timeout)
             status = Status.SUCCESS
         finally:
             duration = round(time.monotonic() - started, 3)
@@ -99,6 +118,20 @@ class Run:
         ctx.log.debug(f"result: {result.summary}")
         return self._with_jobs(result)
 
+    async def _run_plugin(
+        self, plugin: Plugin, item: Item, ctx: Context, timeout: float | None
+    ) -> Item:
+        """plugin.run, stopped after the timeout of the job, the only one; a thread it started (a
+        copy, the requests of gitlab) goes on until it ends."""
+        deadline = asyncio.timeout(timeout)
+        try:
+            async with deadline:
+                return await plugin.run(item, ctx)
+        except TimeoutError:
+            if not deadline.expired():  # raised by the plugin itself
+                raise
+            raise TimeoutError(f"job timed out after {timeout:g} s") from None
+
     def _with_jobs(self, item: Item) -> Item:
         return item.with_data("jobs", dict(self.jobs))
 
diff --git a/src/roger/engine/template.py b/src/roger/engine/template.py
index 97f8b7c..4a3a9e1 100644
--- a/src/roger/engine/template.py
+++ b/src/roger/engine/template.py
@@ -34,6 +34,11 @@ _ENV.filters.update(
     stem=lambda path: PurePosixPath(path).stem,
     dirname=lambda path: str(PurePosixPath(path).parent),
 )
+# "" is no file nor directory (not the current one); an unreadable path is neither, never an error
+_ENV.tests.update(
+    file=lambda path: bool(path) and os.path.isfile(path),
+    dir=lambda path: bool(path) and os.path.isdir(path),
+)
 
 
 @cache
@@ -41,12 +46,19 @@ def _compile(source: str) -> Template:
     return _ENV.from_string(source)
 
 
+@cache
+def _parse(source: str) -> nodes.Template:
+    try:
+        ast = _ENV.parse(source)
+        meta.find_undeclared_variables(ast)  # also refuses an unknown filter or test
+    except TemplateSyntaxError as exc:
+        raise ValueError(f"invalid template {source!r}: {exc.message}") from None
+    return ast
+
+
 def _parsed(value: Any) -> Iterator[nodes.Template]:
     if isinstance(value, str):
-        try:
-            yield _ENV.parse(value)
-        except TemplateSyntaxError as exc:
-            raise ValueError(f"invalid template {value!r}: {exc.message}") from None
+        yield _parse(value)
     elif isinstance(value, dict | list):
         for child in value.values() if isinstance(value, dict) else value:
             yield from _parsed(child)
@@ -93,6 +105,14 @@ def variables(value: Any) -> set[str]:
     return set().union(*(meta.find_undeclared_variables(ast) for ast in _parsed(value)))
 
 
+def is_name(text: str) -> bool:
+    """True when {{ text }} reads the variable text: not a literal (true, none...) nor "a-b"."""
+    try:
+        return variables(f"{{{{ {text} }}}}") == {text}
+    except ValueError:
+        return False
+
+
 def env_names(value: Any) -> set[str]:
     names = set()
     for ast in _parsed(value):
diff --git a/src/roger/engine/watcher.py b/src/roger/engine/watcher.py
index 181e95f..be0d7d9 100644
--- a/src/roger/engine/watcher.py
+++ b/src/roger/engine/watcher.py
@@ -1,5 +1,9 @@
+import asyncio
 import threading
 from abc import ABC, abstractmethod
+from collections.abc import Callable
+from concurrent.futures import Future
+from typing import TypeVar
 
 from pydantic import BaseModel, ConfigDict, PrivateAttr
 
@@ -7,6 +11,24 @@ from roger.engine.models import Event, Item
 from roger.engine.plugin import PluginParams
 from roger.logs import log
 
+T = TypeVar("T")
+
+
+async def in_daemon_thread(func: Callable[[], T]) -> T:
+    """func() in a thread of its own, that roger does not wait for when it exits: a poll blocked
+    on a share that no longer answers cannot hold the stop."""
+    done: Future[T] = Future()
+
+    def run() -> None:
+        if done.set_running_or_notify_cancel():
+            try:
+                done.set_result(func())
+            except BaseException as exc:
+                done.set_exception(exc)
+
+    threading.Thread(target=run, daemon=True).start()
+    return await asyncio.wrap_future(done)
+
 
 class Watcher(BaseModel, ABC):
     model_config = ConfigDict(extra="forbid")
diff --git a/src/roger/plugins/exec.py b/src/roger/plugins/exec.py
index 86f3a34..e7f3f48 100644
--- a/src/roger/plugins/exec.py
+++ b/src/roger/plugins/exec.py
@@ -10,7 +10,7 @@ from typing import Annotated
 
 from pydantic import Field
 
-from roger.engine.models import Context, Duration, Item, error_text
+from roger.engine.models import Context, Item, error_text
 from roger.engine.plugin import Plugin, PluginParams
 
 Command = Annotated[list[str], Field(min_length=1)]
@@ -20,7 +20,6 @@ KILL_AFTER = 5
 class ExecParams(PluginParams):
     dest: str | None = None
     scripts: list[Command] = Field(min_length=1)
-    timeout: Duration = 3600
 
 
 async def _kill(proc: Process) -> None:
@@ -33,7 +32,7 @@ async def _kill(proc: Process) -> None:
     await proc.wait()
 
 
-async def _run(command: list[str], timeout: float, ctx: Context) -> tuple[int, str, str]:
+async def _run(command: list[str], ctx: Context) -> tuple[int, str, str]:
     ctx.log.info(f"running {shlex.join(command)}")
     started = time.monotonic()
     roger_env = {"ROGER_RUN_ID": str(ctx.run_id), "ROGER_WORKDIR": str(ctx.workdir)}
@@ -47,10 +46,7 @@ async def _run(command: list[str], timeout: float, ctx: Context) -> tuple[int, s
         start_new_session=True,
     )
     try:
-        async with asyncio.timeout(timeout):
-            stdout, stderr = await proc.communicate()
-    except TimeoutError:
-        raise TimeoutError(f"timed out after {timeout:g} s") from None
+        stdout, stderr = await proc.communicate()
     finally:
         if proc.returncode is None:
             await _kill(proc)
@@ -83,7 +79,7 @@ class Exec(Plugin):
         errors: list[str] = []
         for command in self.params.scripts:
             try:
-                rc, stdout, stderr = await _run(command, self.params.timeout, ctx)
+                rc, stdout, stderr = await _run(command, ctx)
                 if rc == 0:
                     return command[0], stdout, stderr
                 error = f"exit code {rc}"
diff --git a/src/roger/plugins/gitlab.py b/src/roger/plugins/gitlab.py
index a1b5029..e87b3a6 100644
--- a/src/roger/plugins/gitlab.py
+++ b/src/roger/plugins/gitlab.py
@@ -10,7 +10,7 @@ from gitlab.exceptions import GitlabGetError
 from pydantic import SecretStr
 
 from roger.engine.filesystem import walk_tree
-from roger.engine.models import Context, Duration, Item
+from roger.engine.models import Context, Item
 from roger.engine.plugin import Plugin, TlsParams
 
 
@@ -22,7 +22,6 @@ class GitlabParams(TlsParams):
     branch: str
     dest: str = ""
     message: str | None = None
-    timeout: Duration = 60
 
 
 def _local_files(source: Path, dest: str) -> dict[str, Path]:
@@ -65,7 +64,6 @@ class Gitlab(Plugin):
         client = gitlab.Gitlab(
             self.params.url,
             private_token=self.params.token.get_secret_value(),
-            timeout=self.params.timeout,
             ssl_verify=self.params.ca_bundle(),
         )
         return client.projects.get(self.params.project)
diff --git a/src/roger/plugins/mattermost.py b/src/roger/plugins/mattermost.py
index 084fb76..89a14d5 100644
--- a/src/roger/plugins/mattermost.py
+++ b/src/roger/plugins/mattermost.py
@@ -1,6 +1,6 @@
 from pydantic import JsonValue
 
-from roger.engine.models import Context, Duration, Item
+from roger.engine.models import Context, Item
 from roger.engine.plugin import Plugin, TlsParams
 from roger.plugins.webhook import Webhook, WebhookParams
 
@@ -10,7 +10,6 @@ class MattermostParams(TlsParams):
     message: str
     channel: str | None = None
     api_key: str | None = None
-    timeout: Duration = 10
 
 
 class Mattermost(Plugin):
@@ -25,7 +24,6 @@ class Mattermost(Plugin):
             url=self.params.url,
             body=body,
             headers={"Authorization": f"Bearer {api_key}"} if api_key is not None else {},
-            timeout=self.params.timeout,
             ca_file=self.params.ca_file,
             skip_tls=self.params.skip_tls,
         )
diff --git a/src/roger/plugins/obfuscate.py b/src/roger/plugins/obfuscate.py
index ad6a222..d749206 100644
--- a/src/roger/plugins/obfuscate.py
+++ b/src/roger/plugins/obfuscate.py
@@ -41,16 +41,14 @@ def _rules(words: dict[str, str], regex: dict[re.Pattern[str], str]) -> list[Rul
 
 
 def _obfuscate(source: Path, target: Path, rules: list[Rule]) -> None:
-    partial = target.with_name(f".{target.name}.partial")
     with (
         source.open(encoding="utf-8", errors="surrogateescape", newline="") as lines,
-        partial.open("w", encoding="utf-8", errors="surrogateescape", newline="") as out,
+        target.open("w", encoding="utf-8", errors="surrogateescape", newline="") as out,
     ):
         for line in lines:
             for pattern, replacement in rules:
                 line = pattern.sub(replacement, line)
             out.write(line)
-    partial.replace(target)
 
 
 class Obfuscate(Plugin):
diff --git a/src/roger/plugins/webhook.py b/src/roger/plugins/webhook.py
index d67a0e5..8d3f944 100644
--- a/src/roger/plugins/webhook.py
+++ b/src/roger/plugins/webhook.py
@@ -3,7 +3,7 @@ from typing import Literal
 import httpx
 from pydantic import JsonValue
 
-from roger.engine.models import Context, Duration, Item
+from roger.engine.models import Context, Item
 from roger.engine.plugin import Plugin, TlsParams
 
 
@@ -12,7 +12,6 @@ class WebhookParams(TlsParams):
     method: Literal["POST", "PUT"] = "POST"
     body: dict[str, JsonValue] | None = None
     headers: dict[str, str] = {}
-    timeout: Duration = 10
 
 
 class Webhook(Plugin):
@@ -20,13 +19,9 @@ class Webhook(Plugin):
 
     async def run(self, item: Item, ctx: Context) -> Item:
         body = self.params.body if self.params.body is not None else item.model_dump(mode="json")
-        async with httpx.AsyncClient(verify=self.params.ssl_context()) as client:
+        async with httpx.AsyncClient(verify=self.params.ssl_context(), timeout=None) as client:
             response = await client.request(
-                self.params.method,
-                self.params.url,
-                json=body,
-                headers=self.params.headers,
-                timeout=self.params.timeout,
+                self.params.method, self.params.url, json=body, headers=self.params.headers
             )
         response.raise_for_status()
         status, elapsed = response.status_code, response.elapsed.total_seconds()
diff --git a/src/roger/watchers/api.py b/src/roger/watchers/api.py
index 2aa99a1..7f6c960 100644
--- a/src/roger/watchers/api.py
+++ b/src/roger/watchers/api.py
@@ -5,7 +5,7 @@ import httpx
 from pydantic import Field, JsonValue, model_validator
 
 from roger.engine import template
-from roger.engine.models import NAMESPACES, Duration, Event, Item
+from roger.engine.models import NAMESPACES, Event, Item, Timeout
 from roger.engine.plugin import PluginParams, TlsParams
 from roger.engine.watcher import Watcher
 
@@ -24,7 +24,7 @@ class ApiParams(TlsParams):
     items: FieldPath | None = None  # where the list is in the response; None: the response itself
     key: list[FieldPath] = Field(default=["id"], min_length=1)  # fields that identify an element
     ack: AckParams | None = None
-    timeout: Duration = 10
+    timeout: Timeout = 10
 
     @model_validator(mode="after")
     def _check(self) -> Self:
diff --git a/src/roger/watchers/filesystem.py b/src/roger/watchers/filesystem.py
index b2c35e2..1341dbf 100644
--- a/src/roger/watchers/filesystem.py
+++ b/src/roger/watchers/filesystem.py
@@ -1,4 +1,3 @@
-import asyncio
 import os
 import time
 from pathlib import Path
@@ -26,7 +25,7 @@ from roger.engine.models import (
     error_text,
 )
 from roger.engine.plugin import PluginParams
-from roger.engine.watcher import Watcher
+from roger.engine.watcher import Watcher, in_daemon_thread
 
 FILE_VARS = {
     "origin_file": "the file (or directory) found by the watcher, which started the run",
@@ -100,7 +99,8 @@ class Filesystem(Watcher):
                 if previous != version:
                     since, was_ready = now, False
                 stable = since < now and now - since >= self.params.stable_for
-                is_ready = baseline or (stable and self._big_enough(version))
+                # ready stays ready while unchanged, what the reference of start_mode new found too
+                is_ready = baseline or was_ready or (stable and self._big_enough(version))
                 seen[relative] = (version, since, is_ready)
                 if is_ready and not was_ready:
                     events.append(self._event(root, relative, match, version))
@@ -131,10 +131,10 @@ class Filesystem(Watcher):
         self.log.debug(f"watching {paths} for the {what} matching {patterns}")
 
     async def poll(self) -> list[Event]:
-        return await asyncio.to_thread(self._poll)
+        return await in_daemon_thread(self._poll)
 
     async def existing(self) -> set[str]:  # one read: all there is known, written or not
-        return {event.key for event in await asyncio.to_thread(self._scan, True)}
+        return {event.key for event in await in_daemon_thread(lambda: self._scan(baseline=True))}
 
     async def open(self, event: Event) -> Item:
         root = Path(str(event.meta["root"]))
diff --git a/tests/conftest.py b/tests/conftest.py
index f8cdb11..7509673 100644
--- a/tests/conftest.py
+++ b/tests/conftest.py
@@ -127,6 +127,7 @@ def files(
     start_mode: str = "all",
     alert_every: int | None = None,
     workers: int | None = None,
+    poll_timeout: float | None = None,
 ) -> str:
     params = f'paths = ["{inbox}"], patterns = ["{pattern}"]'
     watch = f'plugin = "filesystem"\n interval = 10\n start_mode = "{start_mode}"'
@@ -134,6 +135,8 @@ def files(
         watch += f"\n alert_every = {alert_every}"
     if workers is not None:
         watch += f"\n workers = {workers}"
+    if poll_timeout is not None:
+        watch += f"\n poll_timeout = {poll_timeout}"
     return f"watch {{\n {watch}\n params = {{ {params} }}\n}}"
 
 
diff --git a/tests/test_engine.py b/tests/test_engine.py
index 724b65a..0b7a2d2 100644
--- a/tests/test_engine.py
+++ b/tests/test_engine.py
@@ -2,8 +2,10 @@ import asyncio
 import json
 import os
 import signal
-from collections.abc import Callable
+import threading
+from collections.abc import Callable, Iterator
 from pathlib import Path
+from typing import Any
 
 import pytest
 from conftest import MESSAGES, REQUESTS, files, gone, pid_in, pipeline, started
@@ -11,7 +13,9 @@ from conftest import MESSAGES, REQUESTS, files, gone, pid_in, pipeline, started
 from roger.engine.config import Config
 from roger.engine.db import State
 from roger.engine.engine import Engine
+from roger.engine.filesystem import walk_matching
 from roger.engine.models import Status
+from roger.watchers import filesystem
 
 pytestmark = pytest.mark.anyio
 DEBUG = 'job "j" { plugin = "debug" }'
@@ -80,11 +84,76 @@ async def test_when(make_config: Callable[..., Config], inbox: Path, tmp_path: P
       plugin = "debug"
       when   = "{{{{ origin_file | stem == 'test' and data.nope.x }}}}"
     }}"""
-    engine = await started(make_config(pipeline("p", files(inbox), jobs)))
+    hook = f"""on_failure {{
+      job "trace" {{
+        plugin = "touch"
+        params = {{ dest = "{tmp_path}/failed", content = "{{{{ data.jobs.missing.status }}}}" }}
+      }}
+    }}"""
+    engine = await started(make_config(pipeline("p", files(inbox), jobs, hook)))
     assert sorted(await engine.cycle()) == [Status.FAILED, Status.SUCCESS]  # data.nope fails test
     assert (tmp_path / "a.done").exists() and not (tmp_path / "test.done").exists()
     assert (tmp_path / "a.status").read_text() == "success"
     assert (tmp_path / "test.status").read_text() == "skipped"
+    assert (tmp_path / "failed").read_text() == "failed"  # a when that fails: in data.jobs too
+
+
+async def test_vars(make_config: Callable[..., Config], inbox: Path, tmp_path: Path) -> None:
+    for name in ["a.csv", "skip.csv"]:
+        (inbox / name).write_text("x")
+    jobs = f"""vars = {{
+      name   = "{{{{ file | name }}}}"
+      label  = "{{{{ name | upper }}}}-{{{{ pipeline }}}}"
+      dir    = "{{{{ file | dirname }}}}"
+      broken = "{{{{ '/nonexistent' | file_read }}}}"
+    }}
+    job "copy" {{
+      plugin = "copy"
+      when   = "{{{{ name != 'skip.csv' }}}}"
+      params = {{ dest = "{tmp_path}/out" }}
+    }}
+    job "mark" {{
+      plugin = "touch"
+      when   = "{{{{ name != 'skip.csv' }}}}"
+      params = {{ dest = "{tmp_path}/{{{{ label }}}}", content = "{{{{ dir }}}}" }}
+    }}"""
+    engine = await started(make_config(pipeline("p", files(inbox), jobs)))
+    assert await engine.cycle() == [Status.SUCCESS, Status.SUCCESS]  # broken: never used
+    assert (tmp_path / "A.CSV-p").read_text() == f"{tmp_path}/out"  # dir follows the copy
+    assert not (tmp_path / "SKIP.CSV-p").exists()
+
+
+async def test_a_var_that_fails(
+    make_config: Callable[..., Config], inbox: Path, tmp_path: Path
+) -> None:
+    (inbox / "a.csv").write_text("x")
+    jobs = f"""vars = {{
+      root  = "{tmp_path}"
+      op_id = "{{{{ (root ~ '/' ~ (file | stem) ~ '.id') | file_read }}}}"
+    }}
+    job "parse" {{
+      plugin = "exec"
+      params = {{ scripts = [["echo", "{{{{ op_id }}}}"]] }}
+    }}"""
+    alert = """on_failure {
+      job "alert" {
+        plugin = "touch"
+        params = { dest = "{{ root }}/alert", content = "{{ data.failure.error }}" }
+      }
+    }"""
+    config = make_config(
+        pipeline("p", files(inbox), jobs, alert),
+        pipeline("down", files(tmp_path / "gone"), jobs, alert.replace("/alert", "/down")),
+    )
+    engine = await started(config)
+    assert await engine.cycle() == [Status.FAILED, Status.FAILED]
+    error = (tmp_path / "alert").read_text()  # the hook uses the var root: computed for it
+    assert error.startswith("ValueError: var op_id: FileNotFoundError: [Errno 2]")
+    assert (tmp_path / "down").read_text().startswith("FileNotFoundError")  # a poll that failed
+    (tmp_path / "a.id").write_text("42")
+    (inbox / "a.csv").write_text("version 2")
+    assert await engine.cycle() == []  # a.csv seen once; down alerted less than an hour ago
+    assert await engine.cycle() == [Status.SUCCESS]
 
 
 async def test_file_and_origin_file(
@@ -253,6 +322,78 @@ async def test_a_poll_stopped_is_no_failure(
     assert not (tmp_path / "alert").exists()
 
 
+async def test_job_timeout(make_config: Callable[..., Config], inbox: Path, tmp_path: Path) -> None:
+    (inbox / "a.csv").write_text("x")
+    pid_file = tmp_path / "pid"
+    script = f'["sh", "-c", "echo $$ > {pid_file}; exec sleep 30"]'
+    slow = (
+        f'job "slow" {{\n plugin = "exec"\n timeout = 0.5\n params = {{ scripts = [{script}] }}\n}}'
+    )
+    engine = await started(make_config(pipeline("p", files(inbox), slow)))
+    assert await engine.cycle() == [Status.FAILED]
+    errors = [run["error"] for run in engine.state.runs(Status.FAILED)]
+    assert errors == ["TimeoutError: job timed out after 0.5 s"]
+    assert await gone(int(pid_file.read_text()))  # exec stops its script
+
+
+@pytest.fixture
+def blocked_share(monkeypatch: pytest.MonkeyPatch) -> Iterator[tuple[threading.Event, list[str]]]:
+    """Each walk of the filesystem watcher waits until the share answers again."""
+    answers, walks = threading.Event(), []
+
+    def walk(root: str, *args: Any) -> Any:
+        walks.append(root)
+        answers.wait()
+        return walk_matching(root, *args)
+
+    monkeypatch.setattr(filesystem, "walk_matching", walk)
+    yield answers, walks
+    answers.set()  # the threads left behind end
+
+
+async def test_a_blocked_poll_fails_and_no_other_starts(
+    make_config: Callable[..., Config],
+    inbox: Path,
+    tmp_path: Path,
+    blocked_share: tuple[threading.Event, list[str]],
+) -> None:
+    (inbox / "a.csv").write_text("x")
+    alert = f"""on_failure {{
+      job "alert" {{
+        plugin = "touch"
+        params = {{
+          dest    = "{tmp_path}/alert-{{{{ run_id }}}}"
+          content = "{{{{ data.failure.error }}}}"
+        }}
+      }}
+    }}"""
+    engine = await started(make_config(pipeline("p", files(inbox, poll_timeout=0.2), DEBUG, alert)))
+    assert await engine.cycle() == [Status.FAILED]  # the alert
+    assert (tmp_path / "alert-1").read_text() == (
+        "TimeoutError: still running after 0.2 s: no other poll until it ends"
+    )
+    assert await engine.cycle() == []  # still blocked: failing, alerted less than an hour ago
+    answers, walks = blocked_share
+    assert len(walks) == 1  # no other poll started
+    answers.set()
+    while engine._pipelines[0]._polling is not None and not engine._pipelines[0]._polling.done():
+        await asyncio.sleep(0.01)
+    assert await engine.cycle() == [Status.SUCCESS]  # the blocked poll ended: its events
+
+
+async def test_a_blocked_poll_does_not_hold_the_stop(
+    make_config: Callable[..., Config],
+    inbox: Path,
+    blocked_share: tuple[threading.Event, list[str]],
+) -> None:
+    engine = await started(make_config(pipeline("p", files(inbox), DEBUG)))
+    task = asyncio.create_task(engine.cycle())
+    while not blocked_share[1]:
+        await asyncio.sleep(0.01)
+    engine._stop(signal.SIGINT)
+    assert await asyncio.wait_for(task, 5) == []  # at once, not after poll_timeout
+
+
 async def test_api_pipeline(make_config: Callable[..., Config], server: str) -> None:
     MESSAGES[:] = [{"id": 1, "subject": "before the start"}]
     watch = f"""watch {{
diff --git a/tests/test_units.py b/tests/test_units.py
index 3aa9886..5a6c91a 100644
--- a/tests/test_units.py
+++ b/tests/test_units.py
@@ -1,6 +1,7 @@
 import asyncio
 import os
 import re
+import shutil
 import sys
 import threading
 from collections.abc import Callable, Iterator
@@ -15,7 +16,7 @@ from jinja2 import UndefinedError
 from pydantic import ValidationError
 
 from roger.engine.config import load_config
-from roger.engine.filesystem import directory_version, matches_at_any_depth
+from roger.engine.filesystem import copy_tree, directory_version, matches_at_any_depth
 from roger.engine.models import Context, Item, RogerError
 from roger.engine.template import render, render_params, variables
 from roger.plugins import exec as exec_plugin
@@ -29,11 +30,20 @@ from roger.watchers import filesystem
 from roger.watchers.filesystem import Filesystem, FilesystemParams
 from roger.watchers.timer import TimerParams, last_time
 
+DEBUG = 'job "j" { plugin = "debug" }'
+
 
 def test_template(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
     monkeypatch.setenv("ROGER_TOKEN", "s3cret")
     (tmp_path / "id").write_text("id-42\n\n")  # file_read drops the last line break only
     assert render(f"[{{{{ '{tmp_path}/id' | file_read }}}}]", {}, {}) == "[id-42\n]"
+    fallback = "{{ (path if path is file else default) | file_read }}"  # the default is not read
+    paths = {"path": f"{tmp_path}/id", "default": f"{tmp_path}/none"}
+    assert render(fallback, paths, {}) == "id-42\n"
+    assert render(fallback, {**paths, "path": f"{tmp_path}/no", "default": paths["path"]}, {})
+    kinds = "{{ [a is file, a is dir, b is file, b is dir, c is dir, '' is dir] }}"
+    paths = {"a": f"{tmp_path}/id", "b": str(tmp_path), "c": f"{tmp_path}/no"}
+    assert render(kinds, paths, {}) == "[true, false, false, true, false, false]"
     value = {
         "a": r"^\d{8}_{{ client | upper }}$",
         "b": ["{{ data.roles.1 }}", 3, "{{ data.roles }}"],
@@ -51,6 +61,8 @@ def test_template(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
         render("{{ data.nope }}", {}, {})
     with pytest.raises(ValueError, match="invalid template"):
         variables("{{ client")
+    with pytest.raises(ValueError, match="No test named 'fil'"):  # at startup, not in a run
+        variables("{{ client is fil }}")
 
 
 @pytest.mark.anyio
@@ -64,8 +76,6 @@ async def test_exec_script(item: Item, ctx: Context) -> None:
     assert (await python(code)).data == {"check": {"stdout": stdout, "stderr": "", "rc": 0}}
     with pytest.raises(RuntimeError, match="exit code 3"):
         await python("raise SystemExit(3)")
-    with pytest.raises(RuntimeError, match=r"timed out after 0\.2 s"):
-        await python("import time; time.sleep(5)", timeout=0.2)
 
 
 @pytest.mark.anyio
@@ -106,6 +116,11 @@ async def test_exec_cancelled_kills_its_processes(
             'job "j" {\n plugin = "debug"\n when = "{{ level }}"\n params = { level = "info" }\n}',
             "job j: unknown variable(s) level; available:",  # when cannot see the params
         ),
+        ('job "j" {\n plugin = "debug"\n timeout = 0\n}', "jobs.j.timeout: Input should be"),
+        (
+            'job "j" {\n plugin = "exec"\n params = { scripts = [["true"]], timeout = 60 }\n}',
+            "invalid params for plugin exec: timeout: Extra inputs",  # the timeout of the job
+        ),
         ('job "j" { plugin = "debug" }\njob "j" { plugin = "debug" }', "duplicate job names: j"),
         (
             'job "jobs" { plugin = "debug" }',
@@ -119,6 +134,19 @@ async def test_exec_cancelled_kills_its_processes(
             'job "j" { plugin = "debug" }\non_watch_failure {\n job "a" { plugin = "debug" }\n}',
             "on_watch_failure: Extra inputs are not permitted",
         ),
+        (
+            f'vars = {{ b = "{{{{ a }}}}", a = "x" }}\n{DEBUG}',  # only the vars written before
+            "vars: unknown variable(s) a; available: pipeline, run_id, file, relpath,",
+        ),
+        (f'vars = {{ file = "x" }}\n{DEBUG}', 'var "file" is reserved: the current file'),
+        (f'vars = {{ "a-b" = "x" }}\n{DEBUG}', 'var "a-b": not a name that a template can use'),
+        (f'vars = {{ true = "x" }}\n{DEBUG}', 'var "true": not a name that a template can use'),
+        (
+            'vars = { out = "x" }\njob "j" {\n plugin = "exec"\n'
+            ' params = { scripts = [["{{ out }}", "{{ outt }}"]] }\n}',
+            "job j: unknown variable(s) outt; available: pipeline, run_id, file, relpath,"
+            " origin_file, origin_relpath, out,",
+        ),
     ],
 )
 def test_invalid_config(
@@ -305,8 +333,13 @@ async def test_filesystem_stable_for(tmp_path: Path, monkeypatch: pytest.MonkeyP
     await restarted.start()
     clock[0] = 151
     assert len(await restarted.existing()) == 2  # start_mode new: unchanged since the start
+    clock[0] = 152
+    assert (await names(restarted), restarted.waiting) == ([], 0)  # there at startup: not waiting
+    (tmp_path / "b.csv").write_text("12")
+    clock[0] = 153
+    assert (await names(restarted), restarted.waiting) == ([], 1)  # changed since: it waits
     clock[0] = 1000
-    assert await names(restarted) == []  # there at startup: never given
+    assert await names(restarted) == ["b.csv"]  # given once stable; a.csv, unchanged, never
 
 
 @pytest.mark.anyio
@@ -377,6 +410,10 @@ async def test_gitlab(gitlab_server: tuple[str, dict[str, dict[str, bytes]]], ct
     assert result.data["check"] == "commit-1"
     assert (await Gitlab(params=params).run(item, ctx)).data["check"] == "commit-1"  # no change
     assert "s3cret" not in str(params.model_dump(mode="json"))
+    with pytest.raises(ValueError, match="is a symbolic link"):  # not "nothing to push"
+        await Gitlab(params=params).run(Item(file=site / "leak.txt"), ctx)
+    with pytest.raises(FileNotFoundError):
+        await Gitlab(params=params).run(Item(file=site / "gone"), ctx)
     feature = params.model_copy(update={"branch": "feature", "dest": "docs"})  # created from main
     await Gitlab(params=feature).run(Item(file=ctx.workdir / "notes.txt"), ctx)
     assert branches["feature"] == {**repository, "docs/notes.txt": b"notes"}
@@ -402,18 +439,25 @@ async def test_copy(tmp_path: Path, ctx: Context) -> None:
     assert (await Copy(params=other).run(Item(), ctx)).file == ctx.workdir / "kept" / "b.csv"
     again = CopyParams(src="kept/b.csv", dest="again")  # relative: from the work directory
     assert (await Copy(params=again).run(Item(), ctx)).file == ctx.workdir / "again" / "b.csv"
-    tree = tmp_path / "logs"  # a directory, with all its tree, like cp -r
+    tree = tmp_path / "logs"  # a directory: its content, with all its tree, as rsync -r logs/
     for name in ["a", "b", "empty"]:
         (tree / name).mkdir(parents=True)
     (tree / "a" / "x.log").write_text("1")
     (tree / "b" / "x.log").write_text("2")
     (tree / "link.log").symlink_to(tree / "a" / "x.log")  # skipped
-    with pytest.raises(ValueError, match="is inside"):  # it would move the tree into itself
-        await Copy(params=CopyParams(dest=f"{tree}/sub", move=True)).run(Item(file=tree), ctx)
+    (tmp_path / "link").symlink_to(tree)
+    for link in [tree / "link.log", tmp_path / "link"]:  # given itself: a failure, no copy
+        with pytest.raises(ValueError, match="is a symbolic link: links are not followed"):
+            await Copy(params=CopyParams(src=str(link), dest="links")).run(Item(), ctx)
+    assert not (ctx.workdir / "links").exists()
+    for inside in [f"{tree}/sub", str(tree)]:  # it would move the tree into itself
+        with pytest.raises(ValueError, match="is inside"):
+            await Copy(params=CopyParams(dest=inside, move=True)).run(Item(file=tree), ctx)
     moved = await Copy(params=CopyParams(dest=f"{tmp_path}/moved", move=True)).run(
         Item(file=tree), ctx
     )
-    assert moved.file == tmp_path / "moved" / "logs"
+    assert moved.file == tmp_path / "moved"
+    assert moved.template_vars["relpath"] == "."  # the copy of the directory is dest itself
     copies = sorted(p.relative_to(moved.file).as_posix() for p in moved.file.rglob("*"))
     assert copies == ["a", "a/x.log", "b", "b/x.log", "empty"]
     assert [p.name for p in tree.iterdir()] == ["link.log"]  # not moved: kept, never deleted
@@ -426,6 +470,32 @@ async def test_copy(tmp_path: Path, ctx: Context) -> None:
         (tmp_path / "locked" / "secret").chmod(0o755)
 
 
+@pytest.mark.anyio
+async def test_copy_writes_under_a_temporary_name(tmp_path: Path, ctx: Context) -> None:
+    source, out = tmp_path / "a.csv", tmp_path / "out"
+    source.write_text("new")
+    out.mkdir()
+    (out / "a.csv").write_text("old")
+    during: list[tuple[str, str]] = []
+
+    def copy(path: Path, partial: Path) -> None:
+        during.append((partial.name, (out / "a.csv").read_text()))
+        shutil.copy2(path, partial)
+
+    assert await copy_tree(source, ctx, str(out), copy) == out / "a.csv"
+    assert during == [(".roger-7.partial", "old")]  # the old file stays whole meanwhile
+    assert (out / "a.csv").read_text() == "new"
+
+    def broken(path: Path, partial: Path) -> None:
+        partial.write_text("half")
+        raise OSError("no space left")
+
+    with pytest.raises(OSError, match="no space left"):
+        await copy_tree(source, ctx, str(out), broken)
+    assert [p.name for p in out.iterdir()] == ["a.csv"]  # the partial copy is removed
+    assert (out / "a.csv").read_text() == "new"
+
+
 @pytest.mark.anyio
 async def test_obfuscate(
     write_config: Callable[..., Path], inbox: Path, tmp_path: Path, ctx: Context
@@ -456,7 +526,8 @@ async def test_obfuscate(
     obfuscate = Obfuscate(params=render(params, {}, {}))
     out = ctx.workdir / "out"
     assert (await obfuscate.run(Item(file=log), ctx)).file == out / "app.log"
-    assert (await obfuscate.run(Item(file=tmp_path / "logs"), ctx)).file == out / "logs"
+    directory = Obfuscate(params=render({**params, "dest": "out/logs"}, {}, {}))
+    assert (await directory.run(Item(file=tmp_path / "logs"), ctx)).file == out / "logs"
     given = Obfuscate(params=render({**params, "src": str(log)}, {}, {}))
     assert (await given.run(Item(), ctx)).file == out / "app.log"  # src: no current file needed
     assert (out / "app.log").read_bytes() == b"login [EMAIL] from 10.x.x.x\r\npassword=*** \xff\n"
