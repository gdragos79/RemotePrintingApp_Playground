# Remote Print (Canon TS5100) – v3 (Mock mode)

Three-tier app (Frontend: NGINX, Backend: Flask REST, DB: PostgreSQL) that lets users register/login, upload a file, and "print" it.
Default **mock mode** completes a print job automatically in ~2 seconds. You can enable real IPP later.

## 1) Prereqs (Debian VM)
```bash
sudo apt-get update
sudo apt-get install -y curl jq conntrack telnet
# Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # log out/in after this
# Minikube + kubectl
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-latest.amd64.deb
sudo dpkg -i minikube-latest.amd64.deb
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

Start Minikube:
```bash
minikube start --driver=docker
```

## 2) Build images & load into Minikube
Run from the repo root (this folder):
```bash
docker build -t remote-print-backend:local  -f backend/Dockerfile  .
docker build -t remote-print-frontend:local -f frontend/Dockerfile .
minikube image load remote-print-backend:local
minikube image load remote-print-frontend:local
```

## 3) Deploy
```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/10-postgres-secret.yaml
kubectl apply -f k8s/20-postgres-pvc.yaml
kubectl apply -f k8s/30-postgres-deployment.yaml
kubectl apply -f k8s/40-backend-configmap.yaml
kubectl apply -f k8s/50-backend-deployment.yaml
kubectl apply -f k8s/60-frontend-configmap.yaml
kubectl apply -f k8s/70-frontend-deployment.yaml
kubectl -n remote-print get pods -w
```

Open the app:
```bash
minikube service -n remote-print frontend --url
```
Register → Login → Choose file → Print. Job status becomes **completed** after ~2s.

## 4) CLI test
```bash
cd scripts
./test.sh
```

## 5) Enable real IPP later (optional)
```bash
# Make sure the printer's IPP port is open:
nc -vz <PRINTER_IP> 631 || telnet <PRINTER_IP> 631

# Point backend at the printer:
kubectl -n remote-print patch configmap backend-config --type merge -p "{
  \"data\": { \"ENABLE_IPP\": \"true\",
              \"PRINTER_URI\": \"ipp://<PRINTER_IP>:631/ipp/print\",
              \"PRINTER_NAME\": \"\" } }"
kubectl -n remote-print rollout restart deploy/backend
```
For TLS, use `ipps://<PRINTER_IP>:631/ipp/print` and add `ca-certificates` to the Dockerfile if needed.

## 6) Troubleshooting
- **Backend not Ready**: `kubectl -n remote-print logs deploy/backend`. Readiness uses `engine.connect().scalar(text('SELECT 1'))`.
- **Frontend 502**: wait until backend is **READY 1/1** and Service endpoints exist.
- **User exists**: Login instead or remove from DB:
  ```bash
  PGPOD=$(kubectl -n remote-print get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}')
  kubectl -n remote-print exec -it "$PGPOD" -- psql -U printuser printdb -c "DELETE FROM users WHERE username='alice';"
  ```

Notes:
- Frontend mounts a custom `nginx.conf` via ConfigMap; proxies `/api` to backend.
- Secrets manage DB credentials; PVC persists DB data; Backend uses ConfigMap + Secret; liveness/readiness probes configured.
