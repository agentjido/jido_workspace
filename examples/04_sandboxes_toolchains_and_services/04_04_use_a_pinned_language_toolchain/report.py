import sys
from pathlib import Path

_, source, report = sys.argv
report_text = Path(source).read_text(encoding="utf-8").upper()
Path(report).write_text(report_text, encoding="utf-8")
print(f"Python {sys.version.split()[0]}")
