import sqlite3
import os

DB_PATH = os.path.join(os.path.dirname(__file__), "gym.db")


SEED_DATA = [
    ("Ab_Crunch_Machine",   "https://youtu.be/fl9FSpCpvq0"),
    ("Assisted_Pullup_Dip", "https://youtu.be/gx0RWT7WbmA"),
    ("Back_Extension",      "https://youtube.com/shorts/EBui4Bt5N7o?si=WfAS27qAvmt8-D0d"),
    ("Cable Crossover",     "https://youtu.be/s1O5NV4PctE"),
    ("Lat Pulldown",        "https://youtu.be/ZxgD_89klTQ"),
    ("Leg_Extension",       "https://youtu.be/1DlLe1r0i74"),
    ("Lying_Leg_Curl",      "https://youtu.be/q1cKTmaeQWo"),
    ("Pec Deck",            "https://youtu.be/H4mVGHaK2f4"),
    ("Seated_Cable_Row",    "https://youtu.be/7BkgqzC6WsM"),
    ("Shoulder_Press",      "https://youtu.be/3R14MnZbcpw"),
    ("Sitting Calf Raise",  "https://youtu.be/6O5hh1rBtx8"),
    ("barbell",             "https://youtu.be/Swu1pxRJ4m4"),
    ("dumbell",             "https://youtu.be/0A3EgOztptQ"),
    ("kattle-ball",         "https://youtu.be/h-A7HiTNZ5c"),
    ("leg-press",           "https://youtu.be/K5n2vg3oZa4"),
    ("roller-abs",          "https://youtu.be/Sk8wZXi0_0A"),
]


def init_db():
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS machines (
                name      TEXT PRIMARY KEY,
                video_url TEXT NOT NULL
            )
        """)
        conn.executemany(
            "INSERT OR IGNORE INTO machines (name, video_url) VALUES (?, ?)",
            SEED_DATA,
        )
        conn.commit()


def get_video_url(machine_name: str) -> str | None:
    with sqlite3.connect(DB_PATH) as conn:
        row = conn.execute(
            "SELECT video_url FROM machines WHERE name = ?", (machine_name,)
        ).fetchone()
    return row[0] if row else None
