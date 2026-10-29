from pathlib import Path
import json,re,hashlib,subprocess
p=Path(__file__).parent;binary=Path('/usr/lib/dyld');sdk=Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk/usr/include/sys/fcntl.h');sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
stack=(p/'sampled-cold-diagnostic/startup-stack.txt').read_text();images=subprocess.check_output(['/usr/bin/otool','-l',str(binary)],text=True);uuid='DF42DD9D-AD11-33A7-8849-9AD5DF30A274';assert uuid in stack and uuid in images
lines=(p/'installed-dyld-disassembly.txt').read_text().splitlines();start=next(i for i,l in enumerate(lines) if l.startswith('00000000000470e4\t'));excerpt=lines[start-1:start+85];text='\n'.join(excerpt)+'\n';assert '0000000000047214\tmov\tw2, #0x62' in text and '0000000000047218\tbl\t__ZNK5dyld415SyscallDelegate5fcntlEiiPv' in text
assert 0x470e4+312==0x4721c and 0x18d090000+0x4721c==0x18d0d721c
assert re.search(r'#define F_CHECK_LV\s+98\b',sdk.read_text())
(p/'dyld-map-segments-excerpt.txt').write_text(text);(p/'sdk-library-validation-definition.txt').write_text('\n'.join(l for l in sdk.read_text().splitlines() if '#define F_CHECK_LV' in l)+'\n')
windows=[]
for f in ['startup-stack.txt','load-3-stack.txt','load-8-stack.txt']:
 s=(p/'sampled-cold-diagnostic'/f).read_text();m=re.search(r'^\s+(\d+) Thread_',s,re.M);n=re.search(r'^\s*__fcntl\s+\(in dyld\)\s+(\d+)$',s,re.M);assert m and n and 'mapSegments' in s
 windows.append(dict(file=f,mainSamples=int(m.group(1)),fcntlTopSamples=int(n.group(1))))
rows=json.loads((p/'cold-diagnostic-images.json').read_text());assert all(sha(Path(r['path']))==r['sha256'] and sha(Path(r['object']))==r['objectSha256'] for r in rows)
result=dict(binary=str(binary),binarySha256=sha(binary),sampledUUID=uuid,sdk=str(sdk),sdkSha256=sha(sdk),functionStart='0x470e4',sampledReturnOffset=312,returnAddress='0x4721c',fcntlBranchAddress='0x47218',commandRegister='w2 = 0x62 = 98',sdkSymbol='F_CHECK_LV',loadWindows=windows,coldInputsUnchanged=True,openSourceCorroboration='https://github.com/apple-oss-distributions/dyld/blob/main/dyld/Loader.cpp',sourceBoundary='Public main is corroboration, not asserted identical to the installed binary. Exact installed UUID, instructions and SDK constant establish this callsite.',inferenceBoundary='The blocked library-validation syscall is identified. The responsible kernel/service endpoint and exact cache/queue contribution are not identified. No library-validation or host security bypass is used.')
(p/'binary-attribution.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
