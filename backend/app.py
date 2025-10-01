#!/usr/bin/env python3
import os, threading, time, subprocess
from datetime import datetime, timedelta
from functools import wraps

from flask import Flask, request, jsonify
from flask_cors import CORS
from werkzeug.utils import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash
import jwt

from sqlalchemy import create_engine, Column, Integer, String, DateTime, ForeignKey, Text, text
from sqlalchemy.orm import sessionmaker, declarative_base, relationship
from sqlalchemy.exc import OperationalError

DB_HOST = os.getenv("DB_HOST", "postgres")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "printdb")
DB_USER = os.getenv("DB_USER", "printuser")
DB_PASSWORD = os.getenv("DB_PASSWORD", "printpass")
DATABASE_URL = os.getenv("DATABASE_URL") or f"postgresql+psycopg2://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"

SECRET_KEY = os.getenv("SECRET_KEY", "devsecret_change_me")
JWT_EXPIRE_MINUTES = int(os.getenv("JWT_EXPIRE_MINUTES", "240"))

# Mock mode by default; IPP can be enabled later via ConfigMap
ENABLE_IPP = os.getenv("ENABLE_IPP", "false").lower() == "true"
PRINTER_URI = os.getenv("PRINTER_URI", "")
PRINTER_NAME = os.getenv("PRINTER_NAME", "")

UPLOAD_DIR = os.getenv("UPLOAD_DIR", "/data/uploads")
os.makedirs(UPLOAD_DIR, exist_ok=True)

engine = create_engine(DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)
Base = declarative_base()

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    username = Column(String(255), unique=True, nullable=False)
    password_hash = Column(String(255), nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)
    jobs = relationship("PrintJob", back_populates="user")

class PrintJob(Base):
    __tablename__ = "print_jobs"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    filename = Column(String(512), nullable=False)
    status = Column(String(64), default="queued")
    error = Column(Text, default=None)
    ipp_job_id = Column(String(128), default=None)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    user = relationship("User", back_populates="jobs")

def init_db():
    for _ in range(30):
        try:
            Base.metadata.create_all(engine)
            return
        except OperationalError:
            time.sleep(2)
    raise RuntimeError("DB init failed")

app = Flask(__name__)
CORS(app)

def create_token(user_id, username):
    payload = {"sub": str(user_id), "username": username, "exp": datetime.utcnow() + timedelta(minutes=JWT_EXPIRE_MINUTES)}
    return jwt.encode(payload, SECRET_KEY, algorithm="HS256")

def auth_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return jsonify({"error": "Unauthorized"}), 401
        token = auth.split(" ",1)[1]
        try:
            payload = jwt.decode(token, SECRET_KEY, algorithms=["HS256"])
            request.user_id = int(payload["sub"]); request.username = payload["username"]
        except Exception:
            return jsonify({"error":"Invalid token"}), 401
        return f(*args, **kwargs)
    return wrapper

@app.get("/healthz")
def healthz():
    return "ok", 200

@app.get("/readyz")
def readyz():
    try:
        with engine.connect() as conn:
            conn.scalar(text("SELECT 1"))
        return "ready", 200
    except Exception:
        return "not ready", 503

@app.post("/api/register")
def register():
    data = request.get_json(silent=True) or {}
    u,p = data.get("username"), data.get("password")
    if not u or not p: return jsonify({"error":"username and password required"}), 400
    s = SessionLocal()
    try:
        if s.query(User).filter_by(username=u).first(): return jsonify({"error":"user exists"}), 400
        s.add(User(username=u, password_hash=generate_password_hash(p))); s.commit()
        return jsonify({"message":"registered"}), 201
    finally: s.close()

@app.post("/api/login")
def login():
    data = request.get_json(silent=True) or {}
    u,p = data.get("username"), data.get("password")
    s = SessionLocal()
    try:
        user = s.query(User).filter_by(username=u).first()
        if not user or not check_password_hash(user.password_hash, p):
            return jsonify({"error":"invalid credentials"}), 401
        return jsonify({"token": create_token(user.id, user.username)})
    finally: s.close()

@app.get("/api/me")
@auth_required
def me():
    return jsonify({"id": request.user_id, "username": request.username})

def _run_ipp_print(local_path):
    if not ENABLE_IPP: return (None, None)
    if PRINTER_NAME:
        cmd = ["lp","-d",PRINTER_NAME, local_path]
    elif PRINTER_URI:
        cmd = ["lp","-o", f"printer-uri-supported={PRINTER_URI}", local_path]
    else:
        return (None, "No PRINTER_URI or PRINTER_NAME configured")
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True, timeout=60)
        job_id = None
        for part in out.split():
            if "-" in part and part.split("-")[-1].isdigit():
                job_id = part.strip()
                break
        return (job_id, None)
    except subprocess.CalledProcessError as e:
        return (None, f"lp failed: {e.output}")
    except Exception as e:
        return (None, str(e))

def _async_mock_complete(job_id):
    time.sleep(2)
    s = SessionLocal()
    try:
        job = s.get(PrintJob, job_id)
        if job:
            job.status = "completed"
            s.commit()
    finally:
        s.close()

@app.post("/api/print")
@auth_required
def submit_print():
    if "file" not in request.files: return jsonify({"error":"file is required"}), 400
    f = request.files["file"]
    if f.filename == "": return jsonify({"error":"empty filename"}), 400
    filename = secure_filename(f.filename)
    path = os.path.join(UPLOAD_DIR, f"{int(time.time())}_{filename}")
    f.save(path)

    s = SessionLocal()
    try:
        job = PrintJob(user_id=request.user_id, filename=filename, status="queued")
        s.add(job); s.commit(); job_id = job.id
    finally: s.close()

    if ENABLE_IPP:
        ipp_id, err = _run_ipp_print(path)
        s = SessionLocal()
        try:
            job = s.get(PrintJob, job_id)
            if job:
                if err:
                    job.status="failed"; job.error=err
                else:
                    job.status="printing"; job.ipp_job_id=ipp_id or ""
                s.commit()
        finally: s.close()
    else:
        threading.Thread(target=_async_mock_complete, args=(job_id,), daemon=True).start()

    return jsonify({"job_id": job_id})

@app.get("/api/jobs/<int:job_id>")
@auth_required
def job_status(job_id):
    s = SessionLocal()
    try:
        job = s.query(PrintJob).filter_by(id=job_id, user_id=request.user_id).first()
        if not job: return jsonify({"error":"not found"}), 404
        return jsonify({
            "id": job.id,
            "filename": job.filename,
            "status": job.status,
            "error": job.error,
            "ipp_job_id": job.ipp_job_id,
            "created_at": job.created_at.isoformat(),
            "updated_at": job.updated_at.isoformat()
        })
    finally:
        s.close()

if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=3000)
