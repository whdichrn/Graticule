from pathlib import Path
import os
import subprocess
import sys
import pytest
from graticule.cli import build_parser,preprocess_args,parse_region_string,parse_range_string,parse_slice_string


def test_negative_ranges_and_module_args_are_accepted():
    args=build_parser().parse_args(preprocess_args(['a.nc','-T','-50/50','-R','-180/180/-80/80','--extra-args','-BWSen -t20','-Z']))
    assert args.range=='-50/50' and args.extra_args=='-BWSen -t20'

@pytest.mark.parametrize('fn,value',[(parse_region_string,'1/0/0/1'),(parse_range_string,'1/1'),(parse_range_string,'nan/3'),(parse_slice_string,'time'),(parse_slice_string,'time=1,time=2')])
def test_invalid_inputs(fn,value):
    with pytest.raises(ValueError):fn(value)


def test_cli_batch_and_script_execute(engine,grids,tmp_path):
    output=tmp_path/'batch'
    cmd=[sys.executable,'-m','graticule.cli',*[str(g) for g in grids],'-o',str(output),'--no-coast','--dpi','72']
    res=subprocess.run(cmd,capture_output=True,text=True,timeout=60)
    assert res.returncode==0,res.stderr
    assert len(list(output.glob('*.png')))==2
    path=tmp_path/'plot.sh'
    res=subprocess.run([sys.executable,'-m','graticule.cli',str(grids[0]),'-s','-o',str(path),'--no-coast'],capture_output=True,text=True,timeout=30)
    assert res.returncode==0,res.stderr
    assert 'begin' in path.read_text() and '.sh ' not in path.read_text()
    res=subprocess.run([sys.executable,'-m','graticule.cli',str(grids[1]),'-o',str(tmp_path/'bad.png'),'--slice','time=99'],capture_output=True,text=True,timeout=30)
    assert res.returncode==1 and 'Traceback' not in res.stderr and 'outside' in res.stderr
