#!/bin/bash
# ============================================================
# MediaCore v3.0 FINAL
# Видеохостинг для VRChat с загрузкой, конвертацией,
# выбором плеера, OSC-отправкой и админ-панелью.
# Установка в /opt/mediacore и /opt/video
# ============================================================
set -e

# Цвета
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

# ---------- Проверка root ----------
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Запустите скрипт от root (sudo).${NC}"
   exit 1
fi

# ---------- Поиск SSL-сертификатов в /usr ----------
echo -e "${YELLOW}[0] Поиск SSL-сертификатов в /usr...${NC}"
CERT_FILE=$(ls /usr/*.crt 2>/dev/null | head -1)
KEY_FILE=$(ls /usr/*.key 2>/dev/null | head -1)
if [ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ]; then
    echo -e "${RED}Не найдены .crt и .key в /usr${NC}"
    exit 1
fi
echo "Сертификат: $CERT_FILE"
echo "Ключ:       $KEY_FILE"

# ---------- Проверка предыдущей установки ----------
INSTALL_DIR="/opt/mediacore"
VIDEO_DIR="/opt/video"
SERVICE_FILE="/etc/systemd/system/mediacore.service"
NGINX_CONFIG="/etc/nginx/sites-available/mediacore"

EXISTING=false
if [ -d "$INSTALL_DIR" ] || [ -f "$SERVICE_FILE" ] || [ -f "$NGINX_CONFIG" ]; then
    EXISTING=true
fi

if $EXISTING; then
    echo -e "${BLUE}Найдена предыдущая установка MediaCore.${NC}"
    echo "Выберите действие:"
    echo "  1) Чистая установка (удалить всё, кроме ОС)"
    echo "  2) Удалить с пакетами (полная очистка + apt purge nginx, ffmpeg и др.)"
    echo "  3) Обновить (сохранить видео и БД, заменить код)"
    echo "  4) Выход"
    read -p "Введите номер [1-4]: " ACTION
    case $ACTION in
        1)
            echo -e "${YELLOW}Чистая установка...${NC}"
            systemctl stop mediacore 2>/dev/null || true
            systemctl disable mediacore 2>/dev/null || true
            rm -f "$SERVICE_FILE"
            rm -rf "$INSTALL_DIR" "$VIDEO_DIR"
            rm -f "$NGINX_CONFIG"
            rm -f /etc/nginx/sites-enabled/mediacore
            systemctl reload nginx 2>/dev/null || true
            ;;
        2)
            echo -e "${YELLOW}Удаление с пакетами...${NC}"
            systemctl stop mediacore 2>/dev/null || true
            systemctl disable mediacore 2>/dev/null || true
            rm -f "$SERVICE_FILE"
            rm -rf "$INSTALL_DIR" "$VIDEO_DIR"
            rm -f "$NGINX_CONFIG" /etc/nginx/sites-enabled/mediacore
            apt-get purge -y -qq nginx ffmpeg python3-pip python3-venv 2>/dev/null || true
            apt-get autoremove -y -qq || true
            systemctl reload nginx 2>/dev/null || true
            echo -e "${GREEN}Пакеты удалены.${NC}"
            ;;
        3)
            echo -e "${YELLOW}Обновление MediaCore...${NC}"
            systemctl stop mediacore 2>/dev/null || true
            # Обновляем код из встроенной функции (см. ниже)
            # Так как скрипт всегда последний, просто перезапишем все файлы приложения
            ;;
        4)
            echo "Выход."
            exit 0
            ;;
        *)
            echo "Неверный выбор."
            exit 1
            ;;
    esac
fi

# ---------- Установка системных пакетов ----------
echo -e "${YELLOW}[1/8] Установка системных пакетов...${NC}"
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv nginx ffmpeg curl git unzip sqlite3

# ---------- Создание структуры каталогов ----------
echo -e "${YELLOW}[2/8] Подготовка структуры...${NC}"
mkdir -p "$INSTALL_DIR"/{web,thumbnails,logs,nginx,osc-proxy,playlists}
mkdir -p "$VIDEO_DIR"

# Настройка прав, чтобы Nginx мог читать
chown -R root:www-data "$INSTALL_DIR" "$VIDEO_DIR"
chmod -R 755 "$INSTALL_DIR" "$VIDEO_DIR"
chmod -R 775 "$INSTALL_DIR"/{thumbnails,logs,playlists}  # Нужна запись для Flask

# ---------- Python виртуальное окружение ----------
echo -e "${YELLOW}[3/8] Настройка Python venv...${NC}"
python3 -m venv "$INSTALL_DIR/venv"
source "$INSTALL_DIR/venv/bin/activate"
pip install --upgrade pip -q
pip install flask python-osc bcrypt yt-dlp -q
deactivate

# ---------- Утилиты (utils.py) ----------
echo -e "${YELLOW}[4/8] Создание утилит конвертации...${NC}"
cat > "$INSTALL_DIR/utils.py" << 'UTILSEOF'
import sys, os, subprocess, sqlite3, json
from datetime import datetime

VIDEO_DIR = "/opt/video"
THUMB_DIR = "/opt/mediacore/thumbnails"
DB_PATH = "/opt/mediacore/data.db"

def update_status(video_id, status):
    conn = sqlite3.connect(DB_PATH)
    conn.execute("UPDATE videos SET status=? WHERE id=?", (status, video_id))
    conn.commit()
    conn.close()

def convert_video(input_path, video_id=None):
    filename = os.path.basename(input_path)
    name, _ = os.path.splitext(filename)
    output_name = name + "_ready.mp4"
    output_path = os.path.join(VIDEO_DIR, output_name)

    subprocess.run([
        "ffmpeg", "-y", "-i", input_path,
        "-c:v", "libx264", "-preset", "fast", "-crf", "23",
        "-c:a", "aac", "-b:a", "128k",
        "-movflags", "+faststart",
        output_path
    ], check=True)

    thumb_name = name + ".jpg"
    thumb_path = os.path.join(THUMB_DIR, thumb_name)
    subprocess.run([
        "ffmpeg", "-y", "-i", input_path,
        "-ss", "00:00:02", "-vframes", "1", "-q:v", "3",
        thumb_path
    ], check=True)

    result = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                              "-of", "default=noprint_wrappers=1:nokey=1", output_path],
                            capture_output=True, text=True)
    duration = float(result.stdout.strip()) if result.stdout else 0
    filesize = os.path.getsize(output_path)

    conn = sqlite3.connect(DB_PATH)
    if video_id:
        conn.execute("UPDATE videos SET filename=?, duration=?, filesize=?, thumbnail=?, status='ready' WHERE id=?",
                     (output_name, duration, filesize, thumb_name, video_id))
    else:
        conn.execute("INSERT INTO videos (title, filename, duration, filesize, thumbnail, status, created_at) VALUES (?,?,?,?,?,'ready',?)",
                     (name, output_name, duration, filesize, thumb_name, datetime.now()))
    conn.commit()
    conn.close()
    print(f"Готово: {output_name}")

def fetch_youtube(url, video_id=None):
    subprocess.run(["yt-dlp", "-f", "best[height<=1080]", "-o", f"{VIDEO_DIR}/%(title)s.%(ext)s", url], check=True)
    files = sorted([f for f in os.listdir(VIDEO_DIR) if not f.endswith('_ready.mp4')],
                   key=lambda x: os.path.getmtime(os.path.join(VIDEO_DIR, x)))
    if files:
        newest = files[-1]
        input_path = os.path.join(VIDEO_DIR, newest)
        convert_video(input_path, video_id)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: utils.py convert <input> [video_id]")
        print("       utils.py youtube <url> [video_id]")
        sys.exit(1)
    cmd, arg = sys.argv[1], sys.argv[2]
    vid = sys.argv[3] if len(sys.argv) > 3 else None
    if cmd == "convert":
        convert_video(arg, vid)
    elif cmd == "youtube":
        fetch_youtube(arg, vid)
UTILSEOF
chmod +x "$INSTALL_DIR/utils.py"

# ---------- Flask приложение (app.py) с комментариями моделей ----------
echo -e "${YELLOW}[5/8] Создание Flask-приложения...${NC}"
cat > "$INSTALL_DIR/app.py" << 'APPEOF'
#!/usr/bin/env python3
"""
MediaCore — видеохостинг для VRChat
Модели данных (SQLite):
  videos:
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    filename TEXT,
    original_url TEXT,
    duration REAL,
    filesize INTEGER,
    thumbnail TEXT,
    status TEXT DEFAULT 'processing',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  view_log:
    id INTEGER PRIMARY KEY,
    video_id INTEGER NOT NULL,
    ip TEXT,
    user_agent TEXT,
    viewed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(video_id) REFERENCES videos(id)
  playlists:
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    videos TEXT,                -- JSON-список ID видео
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  settings:
    key TEXT PRIMARY KEY,
    value TEXT
"""
import os, json, subprocess, time, shutil
from datetime import datetime
from flask import Flask, request, jsonify, send_from_directory, session
from werkzeug.utils import secure_filename
import sqlite3

app = Flask(__name__)
app.secret_key = os.urandom(24).hex()

BASE = "/opt/mediacore"
VIDEO = "/opt/video"
THUMB = f"{BASE}/thumbnails"
DB = f"{BASE}/data.db"
ADMIN_PASS = "changeme"

def init_db():
    conn = sqlite3.connect(DB)
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS videos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        filename TEXT,
        original_url TEXT,
        duration REAL,
        filesize INTEGER,
        thumbnail TEXT,
        status TEXT DEFAULT 'processing',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )''')
    c.execute('''CREATE TABLE IF NOT EXISTS view_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        video_id INTEGER NOT NULL,
        ip TEXT,
        user_agent TEXT,
        viewed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY(video_id) REFERENCES videos(id)
    )''')
    c.execute('''CREATE TABLE IF NOT EXISTS playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        videos TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )''')
    c.execute('''CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT
    )''')
    defaults = {'hls_enabled': 'false', 'columns': '4', 'site_title': 'MediaCore'}
    for k,v in defaults.items():
        c.execute("INSERT OR IGNORE INTO settings (key,value) VALUES (?,?)", (k,v))
    conn.commit()
    conn.close()

# ---------- Авторизация ----------
@app.route('/api/login', methods=['POST'])
def login():
    data = request.get_json()
    if data.get('username') == 'admin' and data.get('password') == ADMIN_PASS:
        session['admin'] = True
        return jsonify(success=True)
    return jsonify(success=False), 401

@app.route('/api/logout', methods=['POST'])
def logout():
    session.pop('admin', None)
    return jsonify(success=True)

def is_admin():
    return session.get('admin', False)

# ---------- Публичные API ----------
@app.route('/api/videos')
def list_videos():
    conn = sqlite3.connect(DB)
    c = conn.cursor()
    c.execute("SELECT id, title, duration, filesize, thumbnail FROM videos WHERE status='ready' ORDER BY created_at DESC")
    rows = c.fetchall()
    conn.close()
    return jsonify([{
        'id': r[0], 'title': r[1], 'duration': r[2], 'filesize': r[3],
        'thumbnail': f'/static/thumbnails/{r[4]}' if r[4] else None
    } for r in rows])

@app.route('/api/videos/<int:vid>')
def video_detail(vid):
    conn = sqlite3.connect(DB)
    c = conn.cursor()
    c.execute("SELECT id, title, filename, duration, filesize, thumbnail FROM videos WHERE id=?", (vid,))
    r = c.fetchone()
    conn.close()
    if r:
        return jsonify({
            'id': r[0], 'title': r[1], 'url': f'/videos/{r[2]}',
            'duration': r[3], 'filesize': r[4],
            'thumbnail': f'/static/thumbnails/{r[5]}' if r[5] else None
        })
    return jsonify(error='Not found'), 404

@app.route('/api/view/<int:vid>', methods=['POST'])
def log_view(vid):
    ip = request.remote_addr
    ua = request.headers.get('User-Agent','')
    conn = sqlite3.connect(DB)
    conn.execute("INSERT INTO view_log (video_id, ip, user_agent) VALUES (?,?,?)", (vid, ip, ua))
    conn.commit()
    conn.close()
    return jsonify(success=True)

# ---------- Админские API ----------
@app.route('/api/admin/stats')
def stats():
    if not is_admin(): return jsonify(error='Forbidden'), 403
    conn = sqlite3.connect(DB)
    c = conn.cursor()
    c.execute("SELECT COUNT(*) FROM videos WHERE status='ready'")
    total_videos = c.fetchone()[0]
    c.execute("SELECT COUNT(*) FROM view_log")
    total_views = c.fetchone()[0]
    conn.close()
    return jsonify(total_videos=total_videos, total_views=total_views)

@app.route('/api/admin/logs')
def logs():
    if not is_admin(): return jsonify(error='Forbidden'), 403
    conn = sqlite3.connect(DB)
    c = conn.cursor()
    c.execute("""
        SELECT v.title, l.ip, l.user_agent, l.viewed_at
        FROM view_log l LEFT JOIN videos v ON l.video_id = v.id
        ORDER BY l.viewed_at DESC LIMIT 200
    """)
    rows = c.fetchall()
    conn.close()
    return jsonify([{'video': r[0], 'ip': r[1], 'ua': r[2], 'time': r[3]} for r in rows])

@app.route('/api/admin/upload/file', methods=['POST'])
def upload_file():
    if not is_admin(): return jsonify(error='Forbidden'), 403
    f = request.files.get('file')
    if not f: return jsonify(error='No file'), 400
    fname = secure_filename(f.filename)
    save_path = os.path.join(VIDEO, fname)
    f.save(save_path)
    conn = sqlite3.connect(DB)
    c = conn.cursor()
    c.execute("INSERT INTO videos (title, filename, status) VALUES (?,?,'processing')",
              (os.path.splitext(fname)[0], fname))
    vid = c.lastrowid
    conn.commit()
    conn.close()
    subprocess.Popen([f"{BASE}/venv/bin/python3", f"{BASE}/utils.py", "convert", save_path, str(vid)])
    return jsonify(success=True, video_id=vid)

@app.route('/api/admin/upload/youtube', methods=['POST'])
def upload_youtube():
    if not is_admin(): return jsonify(error='Forbidden'), 403
    url = request.get_json().get('url')
    if not url: return jsonify(error='No URL'), 400
    conn = sqlite3.connect(DB)
    c = conn.cursor()
    c.execute("INSERT INTO videos (title, original_url, status) VALUES ('YouTube видео',?,'processing')", (url,))
    vid = c.lastrowid
    conn.commit()
    conn.close()
    subprocess.Popen([f"{BASE}/venv/bin/python3", f"{BASE}/utils.py", "youtube", url, str(vid)])
    return jsonify(success=True, video_id=vid)

@app.route('/api/admin/delete/<int:vid>', methods=['DELETE'])
def delete_video(vid):
    if not is_admin(): return jsonify(error='Forbidden'), 403
    conn = sqlite3.connect(DB)
    c = conn.cursor()
    c.execute("SELECT filename, thumbnail FROM videos WHERE id=?", (vid,))
    row = c.fetchone()
    if not row: return jsonify(error='Not found'), 404
    fname, thumb = row
    for path in [os.path.join(VIDEO, fname), os.path.join(THUMB, thumb)]:
        if path and os.path.exists(path):
            os.remove(path)
    c.execute("DELETE FROM videos WHERE id=?", (vid,))
    c.execute("DELETE FROM view_log WHERE video_id=?", (vid,))
    conn.commit()
    conn.close()
    return jsonify(success=True)

# ---------- Плейлисты ----------
@app.route('/api/playlists', methods=['GET','POST'])
def playlists():
    if request.method == 'GET':
        conn = sqlite3.connect(DB)
        c = conn.cursor()
        c.execute("SELECT id, name, created_at FROM playlists ORDER BY created_at DESC")
        rows = c.fetchall()
        conn.close()
        return jsonify([{'id': r[0], 'name': r[1], 'created': r[2]} for r in rows])
    else:
        if not is_admin(): return jsonify(error='Forbidden'), 403
        data = request.get_json()
        name = data['name']
        videos = json.dumps(data.get('videos', []))
        conn = sqlite3.connect(DB)
        c = conn.cursor()
        c.execute("INSERT INTO playlists (name, videos) VALUES (?,?)", (name, videos))
        conn.commit()
        conn.close()
        return jsonify(success=True)

@app.route('/api/playlists/<int:pid>', methods=['GET','PUT','DELETE'])
def playlist(pid):
    conn = sqlite3.connect(DB)
    c = conn.cursor()
    if request.method == 'GET':
        c.execute("SELECT * FROM playlists WHERE id=?", (pid,))
        row = c.fetchone()
        conn.close()
        if row:
            return jsonify({'id': row[0], 'name': row[1], 'videos': json.loads(row[2]), 'created': row[3]})
    elif request.method == 'PUT':
        if not is_admin(): return jsonify(error='Forbidden'), 403
        data = request.get_json()
        c.execute("UPDATE playlists SET name=?, videos=? WHERE id=?",
                  (data['name'], json.dumps(data['videos']), pid))
        conn.commit()
        conn.close()
        return jsonify(success=True)
    elif request.method == 'DELETE':
        if not is_admin(): return jsonify(error='Forbidden'), 403
        c.execute("DELETE FROM playlists WHERE id=?", (pid,))
        conn.commit()
        conn.close()
        return jsonify(success=True)
    conn.close()
    return jsonify(error='Not found'), 404

# ---------- Генератор ссылок под плеер ----------
@app.route('/api/generate-link/<int:vid>')
def generate_link(vid):
    player = request.args.get('player','usharp')
    conn = sqlite3.connect(DB)
    c = conn.cursor()
    c.execute("SELECT filename FROM videos WHERE id=?", (vid,))
    row = c.fetchone()
    conn.close()
    if not row: return jsonify(error='Not found'), 404
    base = f"https://foxhome-yip.ru/videos/{row[0]}"
    if player in ('protv','yam','vizvid'):
        return jsonify(url=json.dumps([{"url": base}]), type='json')
    else:
        return jsonify(url=base, type='direct')

# ---------- Настройки ----------
@app.route('/api/settings', methods=['GET','POST'])
def settings():
    conn = sqlite3.connect(DB)
    if request.method == 'GET':
        c = conn.cursor()
        c.execute("SELECT key, value FROM settings")
        rows = c.fetchall()
        conn.close()
        return jsonify({k:v for k,v in rows})
    else:
        if not is_admin(): return jsonify(error='Forbidden'), 403
        data = request.get_json()
        c = conn.cursor()
        for k,v in data.items():
            c.execute("INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)", (k,v))
        conn.commit()
        conn.close()
        return jsonify(success=True)

# ---------- Статика ----------
@app.route('/')
def index():
    return send_from_directory(f'{BASE}/web', 'index.html')

@app.route('/<path:filename>')
def static_files(filename):
    return send_from_directory(f'{BASE}/web', filename)

@app.route('/static/thumbnails/<path:filename>')
def thumb(filename):
    return send_from_directory(THUMB, filename)

if __name__ == '__main__':
    init_db()
    app.run(host='127.0.0.1', port=5000)
APPEOF

# ---------- Веб-интерфейс (HTML, CSS, JS) ----------
echo -e "${YELLOW}[6/8] Создание веб-интерфейса...${NC}"
cat > "$INSTALL_DIR/web/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title id="pageTitle">MediaCore</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <header>
    <div class="logo" id="siteTitle">MediaCore</div>
    <nav>
      <a href="#" id="homeLink">Главная</a>
      <a href="#" id="playlistsLink">Плейлисты</a>
      <a href="#" id="adminLink" style="display:none;">Админка</a>
      <button id="loginBtn">Войти</button>
    </nav>
  </header>
  <main>
    <div id="guestSection">
      <div class="controls">
        <input type="text" id="searchInput" placeholder="Поиск видео...">
        <select id="playerSelect">
          <option value="usharp">USharpVideo</option>
          <option value="protv">ProTV / YamaPlayer</option>
          <option value="iwa">IwaSync3</option>
          <option value="vizvid">VizVid</option>
        </select>
      </div>
      <div id="videoGrid" class="video-grid"></div>
      <div class="recent">
        <h3>Недавно просмотренные</h3>
        <ul id="recentList"></ul>
      </div>
    </div>

    <div id="adminSection" style="display:none;">
      <h2>Администрирование</h2>
      <div class="admin-tabs">
        <button class="tab active" data-tab="upload">Загрузка</button>
        <button class="tab" data-tab="stats">Статистика</button>
        <button class="tab" data-tab="logs">Логи</button>
        <button class="tab" data-tab="settings">Настройки</button>
        <button class="tab" data-tab="playlists-admin">Плейлисты</button>
      </div>
      <div id="tab-upload" class="tab-panel active">
        <h3>Загрузить файл</h3>
        <input type="file" id="fileInput">
        <div id="fileProgress" class="progress-bar" style="display:none;"><div class="bar"></div><span class="percent">0%</span></div>
        <button id="uploadFileBtn">Загрузить</button>
        <h3>Загрузить с YouTube</h3>
        <input type="text" id="youtubeUrl" placeholder="https://youtube.com/watch?v=...">
        <button id="uploadYoutubeBtn">Загрузить</button>
        <div id="youtubeProgress" class="progress-bar" style="display:none;"><div class="bar"></div><span class="percent">0%</span></div>
      </div>
      <div id="tab-stats" class="tab-panel"><p>Загрузка...</p></div>
      <div id="tab-logs" class="tab-panel"><p>Загрузка...</p></div>
      <div id="tab-settings" class="tab-panel">
        <label>Колонок в галерее:</label>
        <input type="number" id="settingCols" min="1" max="6">
        <label>Включить HLS:</label>
        <input type="checkbox" id="settingHls">
        <label>Заголовок сайта:</label>
        <input type="text" id="settingTitle">
        <button id="saveSettingsBtn">Сохранить</button>
      </div>
      <div id="tab-playlists-admin" class="tab-panel">
        <input type="text" id="newPlaylistName" placeholder="Название плейлиста">
        <button id="createPlaylistBtn">Создать</button>
        <ul id="adminPlaylistList"></ul>
      </div>
    </div>
  </main>
  <footer>
    <p><span id="footerTitle">MediaCore</span> v3.0 | <a href="/get/osc_bridge.py" download>Скачать OSC-прокси</a> | <a href="#" id="howToOsc">Как отправить в VRChat?</a></p>
  </footer>
  <div id="oscModal" class="modal" style="display:none;">
    <div class="modal-content">
      <span class="close">&times;</span>
      <h2>Отправка видео в VRChat</h2>
      <p>1. Установите Python (если ещё нет) с <a href="https://python.org" target="_blank">python.org</a></p>
      <p>2. Скачайте <a href="/get/osc_bridge.py" download>osc_bridge.py</a></p>
      <p>3. Запустите в терминале:<br><code>pip install flask python-osc</code><br><code>python osc_bridge.py</code></p>
      <p>4. Прокси запустится на localhost:9999. Теперь кнопка «Отправить в VRChat» будет работать.</p>
    </div>
  </div>
  <script src="app.js"></script>
</body>
</html>
HTMLEOF

cat > "$INSTALL_DIR/web/style.css" << 'CSSEOF'
:root {
  --bg: #0a0e14;
  --surface: #141b22;
  --accent: #00e5ff;
  --text: #e0e0e0;
  --text-secondary: #8892a0;
  --font: 'Inter', sans-serif;
  --mono: 'JetBrains Mono', monospace;
}
* { margin:0; padding:0; box-sizing:border-box; }
body {
  background:var(--bg);
  color:var(--text);
  font-family:var(--font);
  display:flex;
  flex-direction:column;
  min-height:100vh;
}
a { color:var(--accent); text-decoration:none; }
header {
  background:var(--surface);
  padding:0 20px;
  height:56px;
  display:flex;
  align-items:center;
  justify-content:space-between;
  border-bottom:1px solid #1e2a38;
}
.logo {
  font-family:var(--mono);
  font-size:20px;
  color:var(--accent);
  font-weight:600;
  letter-spacing:2px;
}
nav a, nav button {
  margin-left:15px;
  color:var(--text);
  text-decoration:none;
  font-weight:500;
  cursor:pointer;
  background:none;
  border:none;
  font-size:16px;
}
nav button#loginBtn {
  background:var(--accent);
  color:#000;
  padding:6px 15px;
  border-radius:4px;
  font-family:var(--mono);
  font-weight:600;
}
main {
  flex:1;
  padding:20px;
}
.controls {
  display:flex;
  gap:10px;
  margin-bottom:20px;
  flex-wrap:wrap;
}
.controls input, .controls select {
  padding:10px;
  background:var(--surface);
  border:1px solid #2a3a4a;
  color:var(--text);
  border-radius:4px;
  font-family:var(--mono);
}
.video-grid {
  display:grid;
  grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
  gap:20px;
}
.card {
  background:var(--surface);
  border:1px solid #1e2a38;
  border-radius:4px;
  overflow:hidden;
  transition:0.2s;
}
.card:hover {
  border-color:var(--accent);
  box-shadow:0 0 15px rgba(0,229,255,0.2);
}
.card img {
  width:100%;
  height:140px;
  object-fit:cover;
  background:#111;
}
.card-body {
  padding:10px;
}
.card-title {
  font-weight:600;
  font-size:14px;
  margin-bottom:5px;
  word-break:break-word;
}
.card-info {
  font-size:12px;
  color:var(--text-secondary);
  display:flex;
  justify-content:space-between;
  margin-bottom:10px;
}
.card-actions {
  display:flex;
  gap:5px;
}
.card-actions button {
  flex:1;
  padding:5px;
  font-size:11px;
  background:transparent;
  border:1px solid var(--accent);
  color:var(--accent);
  border-radius:3px;
  cursor:pointer;
  font-family:var(--mono);
}
.admin-tabs {
  display:flex;
  gap:5px;
  margin-bottom:15px;
}
.admin-tabs button {
  background:var(--surface);
  border:1px solid #2a3a4a;
  color:var(--text);
  padding:8px 15px;
  cursor:pointer;
  border-radius:4px;
}
.admin-tabs button.active {
  border-color:var(--accent);
  color:var(--accent);
}
.tab-panel {
  display:none;
}
.tab-panel.active {
  display:block;
}
.progress-bar {
  background:#1e2a38;
  border-radius:4px;
  height:20px;
  margin:10px 0;
  position:relative;
  overflow:hidden;
}
.progress-bar .bar {
  background:var(--accent);
  height:100%;
  width:0%;
  transition: width 0.2s;
}
.progress-bar .percent {
  position:absolute;
  top:0;
  left:50%;
  transform:translateX(-50%);
  font-size:12px;
  line-height:20px;
  color:#000;
}
.recent {
  margin-top:30px;
}
.recent ul {
  list-style:none;
}
.recent li {
  padding:5px;
  cursor:pointer;
  color:var(--accent);
}
footer {
  background:var(--surface);
  text-align:center;
  padding:15px;
  font-size:12px;
  color:var(--text-secondary);
  border-top:1px solid #1e2a38;
}
.modal {
  display:none;
  position:fixed;
  z-index:100;
  left:0;
  top:0;
  width:100%;
  height:100%;
  background:rgba(0,0,0,0.8);
}
.modal-content {
  background:var(--surface);
  margin:10% auto;
  padding:20px;
  width:80%;
  max-width:500px;
  border-radius:4px;
  color:var(--text);
}
.close {
  float:right;
  cursor:pointer;
  font-size:24px;
}
@media (max-width:600px) {
  .video-grid {
    grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
  }
  .controls {
    flex-direction:column;
  }
}
CSSEOF

cat > "$INSTALL_DIR/web/app.js" << 'JSEOF'
let isAdmin = false;
let currentPlayer = 'usharp';
let recent = JSON.parse(localStorage.getItem('recent') || '[]');
let settings = {};

document.addEventListener('DOMContentLoaded', () => {
  loadSettings();
  loadVideos();
  loadRecent();
  setupAdminTabs();

  document.getElementById('loginBtn').onclick = toggleLogin;
  document.getElementById('adminLink').onclick = (e) => { e.preventDefault(); if (!isAdmin) toggleLogin(); };
  document.getElementById('homeLink').onclick = (e) => { e.preventDefault(); showGuest(); };
  document.getElementById('playlistsLink').onclick = (e) => { e.preventDefault(); alert('Плейлисты пока в разработке'); };

  document.getElementById('playerSelect').onchange = function() {
    currentPlayer = this.value;
  };

  document.getElementById('howToOsc').onclick = () => {
    document.getElementById('oscModal').style.display = 'block';
  };
  document.querySelector('.close').onclick = () => {
    document.getElementById('oscModal').style.display = 'none';
  };

  document.getElementById('uploadFileBtn').onclick = uploadFile;
  document.getElementById('uploadYoutubeBtn').onclick = uploadYoutube;
  document.getElementById('saveSettingsBtn').onclick = saveSettings;
  document.getElementById('createPlaylistBtn').onclick = createPlaylist;

  document.getElementById('searchInput').oninput = function() {
    const filter = this.value.toLowerCase();
    document.querySelectorAll('.card').forEach(card => {
      card.style.display = card.querySelector('.card-title').textContent.toLowerCase().includes(filter) ? '' : 'none';
    });
  };
});

function loadSettings() {
  fetch('/api/settings').then(r => r.json()).then(s => {
    settings = s;
    document.getElementById('siteTitle').textContent = s.site_title || 'MediaCore';
    document.getElementById('pageTitle').textContent = s.site_title || 'MediaCore';
    document.getElementById('footerTitle').textContent = s.site_title || 'MediaCore';
    if (s.columns) {
      document.documentElement.style.setProperty('--columns', s.columns);
      document.querySelector('.video-grid').style.gridTemplateColumns = `repeat(auto-fill, minmax(${s.columns === '6' ? '200px' : '250px'}, 1fr))`;
    }
  });
}

function loadVideos() {
  fetch('/api/videos')
    .then(r => r.json())
    .then(videos => {
      const grid = document.getElementById('videoGrid');
      grid.innerHTML = '';
      videos.forEach(v => {
        const card = document.createElement('div');
        card.className = 'card';
        card.innerHTML = `
          <img src="${v.thumbnail || 'placeholder.jpg'}" alt="${v.title}">
          <div class="card-body">
            <div class="card-title">${v.title}</div>
            <div class="card-info">
              <span>${formatDuration(v.duration)}</span>
              <span>${formatSize(v.filesize)}</span>
            </div>
            <div class="card-actions">
              <button class="copy-btn" data-vid="${v.id}">Копировать</button>
              <button class="send-btn" data-vid="${v.id}">Отправить в VRChat</button>
            </div>
          </div>`;
        grid.appendChild(card);
      });
      attachCardButtons();
    });
}

function attachCardButtons() {
  document.querySelectorAll('.copy-btn').forEach(btn => {
    btn.onclick = () => {
      const vid = btn.dataset.vid;
      fetch(`/api/generate-link/${vid}?player=${currentPlayer}`)
        .then(r => r.json())
        .then(data => {
          navigator.clipboard.writeText(data.url).then(() => alert('Ссылка скопирована'));
        });
    };
  });
  document.querySelectorAll('.send-btn').forEach(btn => {
    btn.onclick = () => {
      const vid = btn.dataset.vid;
      fetch(`/api/generate-link/${vid}?player=${currentPlayer}`)
        .then(r => r.json())
        .then(data => {
          const url = data.type === 'json' ? JSON.parse(data.url)[0].url : data.url;
          fetch('http://localhost:9999/send', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({url})
          }).then(() => {
            alert('Отправлено в VRChat');
            addRecent(vid, url);
          }).catch(() => alert('Ошибка: OSC-прокси не запущен. Скачайте и запустите osc_bridge.py'));
        });
    };
  });
}

function addRecent(vid, url) {
  const exists = recent.find(r => r.id == vid);
  if (!exists) {
    recent.unshift({id: vid, url, time: Date.now()});
    if (recent.length > 10) recent.pop();
    localStorage.setItem('recent', JSON.stringify(recent));
    loadRecent();
  }
}

function loadRecent() {
  const ul = document.getElementById('recentList');
  ul.innerHTML = '';
  recent.forEach(r => {
    const li = document.createElement('li');
    li.textContent = `Видео #${r.id}`;
    li.onclick = () => navigator.clipboard.writeText(r.url);
    ul.appendChild(li);
  });
}

function formatDuration(sec) {
  if (!sec) return '?:?';
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2,'0')}`;
}
function formatSize(bytes) {
  if (!bytes) return '?';
  return bytes > 1e6 ? (bytes/1e6).toFixed(1)+' MB' : (bytes/1e3).toFixed(0)+' KB';
}

function toggleLogin() {
  if (isAdmin) {
    fetch('/api/logout', {method:'POST'}).then(() => {
      isAdmin = false;
      document.getElementById('loginBtn').textContent = 'Войти';
      document.getElementById('adminLink').style.display = 'none';
      document.getElementById('adminSection').style.display = 'none';
      document.getElementById('guestSection').style.display = 'block';
    });
  } else {
    const pass = prompt('Пароль администратора');
    if (pass) {
      fetch('/api/login', {
        method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({username:'admin', password:pass})
      }).then(r => r.json()).then(data => {
        if (data.success) {
          isAdmin = true;
          document.getElementById('loginBtn').textContent = 'Выйти';
          document.getElementById('adminLink').style.display = 'inline';
          document.getElementById('adminSection').style.display = 'block';
          document.getElementById('guestSection').style.display = 'none';
          loadAdminStats();
        } else alert('Неверный пароль');
      });
    }
  }
}

function showGuest() {
  if (isAdmin) {
    document.getElementById('adminSection').style.display = 'none';
    document.getElementById('guestSection').style.display = 'block';
  }
}

function setupAdminTabs() {
  document.querySelectorAll('.admin-tabs .tab').forEach(tab => {
    tab.addEventListener('click', () => {
      document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
      document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      document.getElementById(`tab-${tab.dataset.tab}`).classList.add('active');
      if (tab.dataset.tab === 'stats') loadAdminStats();
      if (tab.dataset.tab === 'logs') loadAdminLogs();
      if (tab.dataset.tab === 'settings') loadAdminSettings();
      if (tab.dataset.tab === 'playlists-admin') loadAdminPlaylists();
    });
  });
}

function loadAdminStats() {
  fetch('/api/admin/stats').then(r => r.json()).then(data => {
    document.getElementById('tab-stats').innerHTML = `<p>Всего видео: ${data.total_videos}</p><p>Просмотров: ${data.total_views}</p>`;
  });
}

function loadAdminLogs() {
  fetch('/api/admin/logs').then(r => r.json()).then(logs => {
    const html = logs.map(l => `<div>${l.time} — ${l.video} (${l.ip})</div>`).join('');
    document.getElementById('tab-logs').innerHTML = html || 'Нет записей';
  });
}

function loadAdminSettings() {
  document.getElementById('settingCols').value = settings.columns || '4';
  document.getElementById('settingHls').checked = settings.hls_enabled === 'true';
  document.getElementById('settingTitle').value = settings.site_title || 'MediaCore';
}

function saveSettings() {
  const cols = document.getElementById('settingCols').value;
  const hls = document.getElementById('settingHls').checked;
  const title = document.getElementById('settingTitle').value;
  fetch('/api/settings', {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body: JSON.stringify({columns: cols, hls_enabled: hls ? 'true' : 'false', site_title: title})
  }).then(() => {
    alert('Настройки сохранены');
    loadSettings();
  });
}

function loadAdminPlaylists() {
  fetch('/api/playlists').then(r => r.json()).then(lists => {
    const ul = document.getElementById('adminPlaylistList');
    ul.innerHTML = lists.map(p => `<li>${p.name} <button onclick="deletePlaylist(${p.id})">Удалить</button></li>`).join('');
  });
}

function createPlaylist() {
  const name = document.getElementById('newPlaylistName').value;
  if (!name) return;
  fetch('/api/playlists', {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body: JSON.stringify({name, videos: []})
  }).then(() => {
    document.getElementById('newPlaylistName').value = '';
    loadAdminPlaylists();
  });
}

function deletePlaylist(pid) {
  if (!confirm('Удалить плейлист?')) return;
  fetch(`/api/playlists/${pid}`, {method:'DELETE'}).then(() => loadAdminPlaylists());
}

function uploadFile() {
  const file = document.getElementById('fileInput').files[0];
  if (!file) return;
  const formData = new FormData();
  formData.append('file', file);
  const xhr = new XMLHttpRequest();
  xhr.open('POST', '/api/admin/upload/file');
  xhr.upload.onprogress = (e) => {
    if (e.lengthComputable) {
      const percent = Math.round((e.loaded / e.total) * 100);
      document.getElementById('fileProgress').style.display = 'block';
      document.getElementById('fileProgress').querySelector('.bar').style.width = percent + '%';
      document.getElementById('fileProgress').querySelector('.percent').textContent = percent + '%';
    }
  };
  xhr.onload = () => {
    document.getElementById('fileProgress').style.display = 'none';
    alert('Файл загружен, началась конвертация');
    document.getElementById('fileInput').value = '';
  };
  xhr.send(formData);
}

function uploadYoutube() {
  const url = document.getElementById('youtubeUrl').value;
  if (!url) return;
  fetch('/api/admin/upload/youtube', {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body: JSON.stringify({url})
  }).then(() => {
    alert('Загрузка с YouTube запущена');
    document.getElementById('youtubeUrl').value = '';
  });
}
JSEOF

# ---------- OSC-прокси ----------
echo -e "${YELLOW}[7/8] Настройка OSC-прокси...${NC}"
cat > "$INSTALL_DIR/osc-proxy/osc_bridge.py" << 'OSCEOF'
#!/usr/bin/env python3
import sys
from flask import Flask, request
from pythonosc import udp_client

app = Flask(__name__)
try:
    client = udp_client.SimpleUDPClient("127.0.0.1", 9000)
except Exception as e:
    print("Ошибка OSC клиента:", e)
    sys.exit(1)

@app.route('/send', methods=['POST'])
def send():
    data = request.get_json()
    url = data.get('url')
    if url:
        client.send_message("/chatbox/input", [url, True])
        return {"status": "ok"}
    return {"status": "error", "message": "No URL"}, 400

if __name__ == '__main__':
    print("OSC-прокси запущен на http://localhost:9999")
    app.run(host='127.0.0.1', port=9999)
OSCEOF

ln -sf "$INSTALL_DIR/osc-proxy/osc_bridge.py" "$INSTALL_DIR/web/osc_bridge.py"

# ---------- Nginx конфигурация ----------
echo -e "${YELLOW}[8/8] Настройка Nginx...${NC}"
cat > "$INSTALL_DIR/nginx/mediacore.conf" << NGXEOF
server {
    listen 80;
    server_name foxhome-yip.ru;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name foxhome-yip.ru;

    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /opt/mediacore/web;
    index index.html;

    location /api/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location /videos/ {
        alias /opt/video/;
        add_header Content-Type video/mp4;
        add_header Cache-Control "public, max-age=3600";
    }
    location /static/thumbnails/ {
        alias /opt/mediacore/thumbnails/;
    }
    location /get/ {
        alias /opt/mediacore/web/;
    }
    location = /favicon.ico { access_log off; log_not_found off; }
}
NGXEOF

cp "$INSTALL_DIR/nginx/mediacore.conf" /etc/nginx/sites-available/mediacore
ln -sf /etc/nginx/sites-available/mediacore /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ---------- Systemd сервис ----------
cat > /etc/systemd/system/mediacore.service << SYSTEMDEOF
[Unit]
Description=MediaCore Flask App
After=network.target

[Service]
User=root
Group=www-data
WorkingDirectory=/opt/mediacore
ExecStart=/opt/mediacore/venv/bin/python3 /opt/mediacore/app.py
Restart=always
Environment="PATH=/opt/mediacore/venv/bin"

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

systemctl daemon-reload
systemctl enable mediacore
systemctl start mediacore

# ---------- Запрос пароля администратора ----------
echo -e "${GREEN}Введите пароль администратора (или нажмите Enter для 'admin'):${NC}"
read -s ADMIN_PASSWD
if [ -z "$ADMIN_PASSWD" ]; then
    ADMIN_PASSWD="admin"
fi
# Замена заглушки в app.py
sed -i "s/ADMIN_PASS = \"changeme\"/ADMIN_PASS = \"$ADMIN_PASSWD\"/" "$INSTALL_DIR/app.py"
systemctl restart mediacore

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Установка MediaCore завершена!${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Сайт: https://foxhome-yip.ru"
echo "Логин: admin"
echo "Пароль: $ADMIN_PASSWD"
echo ""
echo "Не забудьте запустить osc_bridge.py на своём ПК для отправки ссылок в VRChat."