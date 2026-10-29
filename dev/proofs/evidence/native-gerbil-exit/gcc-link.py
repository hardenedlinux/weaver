#!/usr/bin/env python3
import os,sys,json
from pathlib import Path
args=['/opt/homebrew/bin/gcc-16',*sys.argv[1:],'-isysroot','/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk','-lSystem']
Path(__file__).with_name('gcc-link-invocation.json').write_text(json.dumps(args,indent=2)+'\n')
os.execv(args[0],args)
