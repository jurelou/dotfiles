diff --git a/README.md b/README.md
index 544ba5c..b767a4a 100644
--- a/README.md
+++ b/README.md
@@ -48,7 +48,7 @@ src/roger/
 └── plugins/          one module per plugin, named like it: webhook, mattermost, gitlab,
     │                 obfuscate, exec
     └── core/         the basic plugins: debug, copy, find, decompress, touch
-deploy/               systemd unit
+deploy/               systemd unit, Containerfile, k8s/ (Kubernetes and OKD)
 ```
 
 ## How the daemon works
@@ -570,6 +570,36 @@ restart. `VENV=`, `PYTHON=` and `CONFIG_DIR=` install elsewhere.
   (zip and gzip work).
 - From the sources: `git clone` into `/opt/roger`, then `uv sync --frozen --no-dev`.
 
+### Kubernetes and OKD
+
+`deploy/Containerfile` builds the image: `tini`, then `roger run`, stopped by SIGINT so that the
+runs finish. `deploy/k8s/` holds the manifests, for kustomize:
+
+| Directory | Holds |
+| --- | --- |
+| `base/` | the Deployment (1 replica, `Recreate`), the volumes `roger-state` (`/var/lib/roger`) and `roger-data` (`/data`, the share: set its storage class), the Service of a `slash` watcher, and `config.hcl` |
+| `kubernetes/` | the namespace, an Ingress, `fsGroup`, the image to pull |
+| `okd/` | the build in the cluster (BuildConfig, ImageStream), a Route |
+
+```sh
+# Kubernetes: push the image, set it in deploy/k8s/kubernetes/kustomization.yaml
+docker build -f deploy/Containerfile -t registry.example.com/roger:0.1.0 .
+kubectl create namespace roger
+kubectl -n roger create secret generic roger-env --from-env-file=env   # NAME=value lines
+kubectl apply -k deploy/k8s/kubernetes
+
+# OKD: the image is built from the last commit, and each build rolls out
+oc new-project roger
+oc create secret generic roger-env --from-env-file=env
+oc apply -k deploy/k8s/okd
+oc start-build roger --from-repo=. --follow
+```
+
+- The configuration is `deploy/k8s/base/config.hcl`: a change rolls out a new pod.
+- The scripts of `exec` run in the container: put them in an image built `FROM` roger.
+- `TZ` (`Europe/Paris`) sets the local time of the `timer` watcher and of the logs.
+- `kubectl exec deploy/roger -- roger status` shows the runs.
+
 ### A CIFS (SMB) share
 
 The owner and the permissions of the files come from the mount options (`cifs-utils` needed,
