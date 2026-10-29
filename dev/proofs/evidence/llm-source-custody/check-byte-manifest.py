from pathlib import Path
import hashlib
p=Path('proofs/evidence/llm-source-custody/SHA256SUMS')
rows=p.read_text().splitlines();assert rows
for row in rows:
 digest,name=row.split('  ',1)
 assert hashlib.sha256(Path(name).read_bytes()).hexdigest()==digest,name
print(f'PASS: {len(rows)} sealed byte targets match')
