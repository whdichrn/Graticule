import json
from pathlib import Path
from dataclasses import replace
import os
import subprocess
import numpy as np
import pytest
from PIL import Image
from graticule.backend.gmt_engine import PlotConfig,parse_gmt_conf


def config(grids,**kw):
    return PlotConfig(str(grids[0])+'?field', region=(0,360,-90,90), projection='W180/16c', dpi=72, **kw)


def test_conf_preserves_font_commas():
    assert parse_gmt_conf('FONT_TITLE=14p,Helvetica,black, MAP_FRAME_TYPE=plain; COLOR_NAN=gray90')=={
        'FONT_TITLE':'14p,Helvetica,black','MAP_FRAME_TYPE':'plain','COLOR_NAN':'gray90'}

@pytest.mark.parametrize('kw',[{'region':(1,0,-10,10)},{'cpt_range':(2,1)},{'cpt_range':(float('nan'),1)},
    {'projection':'M16c'},{'projection':'IntMollOcean','region':(100,120,20,40)},
    {'extra_args':'-JM16c'},{'extra_args':'"bad'},{'dpi':0},{'gmt_conf':'WRONG'}, {'x_interval':-1}])
def test_invalid_config_is_actionable(grids,kw):
    base=config(grids)
    with pytest.raises(ValueError): replace(base,**kw).validate()

@pytest.mark.parametrize('projection,region',[
    ('Q180/16c',(0,360,-90,90)),('W180/16c',(0,360,-90,90)),('R180/16c',(0,360,-90,90)),
    ('S0/90/15c',(0,360,60,90)),('S0/-90/15c',(0,360,-90,-60)),
    ('M16c',(100,130,20,40)),('L115/30/25/35/16c',(100,130,20,40)),
    ('B115/30/25/35/16c',(100,130,20,40)),('IntMollOcean',(0,360,-90,90))])
def test_real_render_geometry_and_colorbar(engine,grids,tmp_path,projection,region):
    cfg=replace(config(grids,title='Readable title + units',colorbar_title='mGal'),projection=projection,region=region)
    path=tmp_path/'map.png'; engine.render(cfg,str(path))
    metadata=json.loads(Path(str(path)+'.map.json').read_text()); left,top,right,bottom=metadata['bbox']
    with Image.open(path) as im:
        assert left>=0 and top>=0 and right<=im.width+1 and bottom<im.height-15
        # Colorbar contributes a substantial non-white band below the map.
        arr=np.asarray(im.convert('RGB'))
        assert np.count_nonzero(np.min(arr[int(bottom)+5:],axis=2)<180)>100


def test_region_scanning_and_masking_are_real(engine,grids):
    spec=str(grids[0])+'?field'
    all_info=engine.get_masked_grid_info(spec,(0,360,-90,90),'none')
    info=engine.get_masked_grid_info(spec,(0,30,-10,10),'none')
    assert all_info['z_min']==-1 and info['z_min']>=0 and info['z_max']<.51
    masked=engine.get_masked_grid_info(spec,(0,360,-90,90),'land')
    assert np.isfinite(masked['z_min']) and np.isfinite(masked['z_max'])


def test_invalid_cpt_is_not_silently_replaced(engine,grids,tmp_path):
    with pytest.raises(RuntimeError,match='makecpt'): engine.render(config(grids,cpt='not_a_real_palette'),str(tmp_path/'bad.png'))


def test_continuous_and_discrete_cpt_values(engine,grids):
    cfg=engine.resolve_config(config(grids,cpt='blue,white,red',cpt_range=(-1,1)))
    for continuous in (True,False):
        cfg=replace(cfg,cpt_continuous=continuous,cpt_levels=8)
        commands=engine._commands(cfg,'unused','png'); args=next(a for a in commands if a[0]=='makecpt')
        res=engine._run(args)
        rows=[r.split() for r in res.stdout.splitlines() if r and not r.startswith(('#','B','F','N'))]
        assert len(rows)==(256 if continuous else 8)
        assert any(r[1]!=r[3] for r in rows)==continuous


def test_exported_script_quotes_and_executes(engine,grids,tmp_path):
    output=tmp_path/'map with spaces.png'
    cfg=config(grids,title='Title $(touch SHOULD_NOT_EXIST) `literal`',cpt_range=(-1,1),show_coast=False,extra_args='-BWSen',gmt_conf='FONT_TITLE=14p,Helvetica,black')
    script=engine.generate_script(cfg,str(output))
    path=tmp_path/'plot.sh'; path.write_text(script)
    env=os.environ.copy();env['PATH']=str(Path(engine.gmt_bin).parent)+os.pathsep+env['PATH']
    res=subprocess.run(['bash',str(path)],cwd=tmp_path,env=env,capture_output=True,text=True,timeout=60)
    assert res.returncode==0,res.stderr
    assert output.exists() and not (tmp_path/'SHOULD_NOT_EXIST').exists()
    restored=engine.parse_script_to_config(script,cfg)
    assert restored.title==cfg.title and restored.projection==cfg.projection and not restored.show_coast
    assert restored.cpt_range==cfg.cpt_range

@pytest.mark.parametrize('fmt',['pdf','svg','tif','jpg','eps'])
def test_export_formats(engine,grids,tmp_path,fmt):
    path=tmp_path/('export.'+fmt);engine.render(config(grids,show_coast=False),str(path))
    assert path.stat().st_size>100


def test_exact_inverse_and_blank_corners(engine):
    r=(100,130,20,40);proj='L115/30/25/35/16c';dims=engine.get_map_dimensions_cm(r,proj)
    source=np.array([[105,25],[115,30],[125,35]])
    res=engine._run(['mapproject',engine._region_flag(r),'-J'+proj,'-Dc','--FORMAT_FLOAT_OUT=%.15g'],input='\n'.join(' '.join(map(str,p)) for p in source))
    points=np.array([list(map(float,line.split()[:2])) for line in res.stdout.splitlines()])/dims
    assert np.allclose(engine.inverse_project_points(points,r,proj,dims),source,atol=1e-8)
    assert np.isnan(engine.inverse_project_points([(0,1)],(0,360,-90,90),'W180/16c',(16,8))).all()


def test_partial_global_ocean_recommendation_is_valid(engine,grids):
    cfg=replace(config(grids),region=(20,340,-60,60),projection_mode='auto',variable_name='sst')
    assert engine.resolve_config(cfg).projection!='IntMollOcean'


def test_script_edits_update_style_frame_and_module_options(engine,grids):
    cfg=config(grids,show_coast=False,cpt_range=(-1,1),extra_args='-t20',show_grid=False,title='Before')
    script=engine.generate_script(cfg).replace('FONT_TITLE 14p,Helvetica','FONT_TITLE 18p,Helvetica').replace('-t20','-t30').replace('-Bxaf','-Bxa30f').replace('-BWSen+tBefore','-BESwn+tAfter')
    restored=engine.parse_script_to_config(script,cfg)
    assert restored.title=='After' and restored.title_size==18
    assert restored.x_interval==30 and restored.frame_sides=='ESwn'
    assert restored.extra_args=='-t30' and not restored.show_grid
    assert 'FONT_TITLE' not in restored.gmt_conf


def test_script_preserves_interrupted_layout_and_hidden_elements(engine,grids):
    cfg=replace(config(grids,show_frame=False,show_colorbar=False,show_coast=False,title='Ocean'),projection='IntMollOcean')
    restored=engine.parse_script_to_config(engine.generate_script(cfg),cfg)
    assert restored.projection=='IntMollOcean' and restored.region==cfg.region
    assert restored.title=='Ocean' and not restored.show_frame and not restored.show_colorbar and not restored.show_coast


def test_preview_lod_is_bounded_and_cached(engine,tmp_path):
    import xarray as xr
    path=tmp_path/'large.nc'
    xr.Dataset({'z':(('lat','lon'),np.zeros((1601,2001),dtype=np.float32))},coords={'lat':np.linspace(-80,80,1601),'lon':np.linspace(0,360,2001)}).to_netcdf(path)
    spec=str(path)+'?z';preview=engine._get_or_create_preview_grid(spec,None)
    assert preview!=spec
    info=engine.get_grid_info(preview,scan=False)
    assert info['nx']==2000 and info['ny']==1000
    assert engine._get_or_create_preview_grid(spec,None)==preview


def test_cache_updates_when_source_changes(engine,grids):
    import xarray as xr
    path=grids[0];spec=str(path)+'?field'
    assert engine.get_grid_info(spec)['z_max']==1
    with xr.open_dataset(path) as data: new=data.load().copy(deep=True)
    new['field']=new['field']*10
    new.to_netcdf(path,mode='w')
    assert engine.get_grid_info(spec)['z_max']==10

@pytest.mark.parametrize('projection,frame',[('IntMollOcean',True),('W180/16c',False)])
def test_title_remains_visible_without_an_outer_rectangle(engine,grids,tmp_path,projection,frame):
    cfg=replace(config(grids,title='Visible title',show_coast=False),projection=projection,show_frame=frame)
    path=tmp_path/'title.png';engine.render(cfg,str(path))
    top=json.loads(Path(str(path)+'.map.json').read_text())['bbox'][1]
    with Image.open(path) as im:
        assert top>12
        arr=np.asarray(im.convert('RGB'))
        assert np.count_nonzero(np.min(arr[:int(top)-3],axis=2)<100)>10


def test_custom_ellipsoid_uses_same_forward_inverse_settings(engine):
    region=(100,130,20,40);proj='M16c';conf='PROJ_ELLIPSOID=Sphere'
    dims=engine.get_map_dimensions_cm(region,proj,conf)
    forward=engine._run(['mapproject',engine._region_flag(region),'-J'+proj,'-Dc','--PROJ_ELLIPSOID=Sphere','--FORMAT_FLOAT_OUT=%.15g'],input='112 32')
    uv=np.array(list(map(float,forward.stdout.split()[:2])))/dims
    result=engine.inverse_project_points([uv],region,proj,dims,conf)
    assert np.allclose(result,[[112,32]],atol=1e-8)


def test_automatic_projection_retains_variable_metadata_context(engine,grids):
    cfg=replace(config(grids),projection_mode='auto',variable_name='z',variable_description='sea surface temperature over ocean basins')
    assert engine.resolve_config(cfg).projection=='IntMollOcean'


def test_fast_netcdf_subgrid_handles_descending_lat_and_pixel_global(engine, tmp_path):
    import xarray as xr
    path = tmp_path / 'desc_global.nc'
    lon = np.linspace(-179.5, 179.5, 360)
    lat = np.linspace(89.5, -89.5, 180)  # descending latitude, pixel-registered global
    data = (lat[:, None] * 10.0 + lon[None, :] * 0.1).astype(np.float32)
    xr.Dataset({'elevation': (('lat', 'lon'), data)}, coords={'lat': lat, 'lon': lon}).to_netcdf(path)

    out_global = tmp_path / 'sub_global.nc'
    ok = engine._fast_netcdf_subgrid(f'{path}?elevation', (-179.5, 179.5, -89.5, 89.5), str(out_global), max_nx=120, max_ny=60)
    assert ok
    info = engine.get_grid_info(str(out_global))
    assert info['nx'] == 120 and info['ny'] == 60
    assert info['x_min'] == -180.0 and info['x_max'] == 180.0
    assert info['y_min'] == -90.0 and info['y_max'] == 90.0

    # Ensure ascending latitude ordering & correct values at North/South poles
    with xr.open_dataset(out_global) as ds:
        assert ds['lat'].values[0] < ds['lat'].values[-1]
        assert float(ds['z'].isel(lat=-1).mean()) > float(ds['z'].isel(lat=0).mean())

    out_reg = tmp_path / 'sub_reg.nc'
    ok_reg = engine._fast_netcdf_subgrid(f'{path}?elevation', (100.0, 130.0, 10.0, 40.0), str(out_reg), max_nx=50, max_ny=50)
    assert ok_reg
    reg_info = engine.get_grid_info(str(out_reg))
    assert reg_info['x_min'] <= 100.0 and reg_info['x_max'] >= 130.0
    assert reg_info['y_min'] <= 10.0 and reg_info['y_max'] >= 40.0


def test_get_masked_grid_info_skips_grdcut_on_full_region(engine, grids, monkeypatch):
    spec = str(grids[0]) + '?field'
    calls = []
    orig_run = engine._run

    def spy_run(args, input=None):
        calls.append(args[0])
        return orig_run(args, input=input)

    monkeypatch.setattr(engine, '_run', spy_run)
    info = engine.get_masked_grid_info(spec, (0.0, 360.0, -90.0, 90.0), 'none')
    assert 'grdcut' not in calls
    assert info['z_min'] == -1.0 and info['z_max'] == 1.0


def test_high_arctic_polar_on_180_global_grid_and_title_offset(engine, tmp_path):
    import xarray as xr
    path = tmp_path / 'global180.nc'
    lon = np.linspace(-179.5, 179.5, 360)
    lat = np.linspace(-89.5, 89.5, 180)
    data = np.broadcast_to(lat[:, None].astype(np.float32), (180, 360)).copy()
    xr.Dataset({'elevation': (('lat', 'lon'), data)}, coords={'lat': lat, 'lon': lon}).to_netcdf(path)

    cfg = PlotConfig(
        f'{path}?elevation',
        region=(0.0, 360.0, 75.0, 90.0),
        projection='S0/90/15c',
        projection_mode='manual',
        title='Elevation [High Arctic 75°N–90°N]',
        show_coast=False,
        dpi=200,
        preview=True,
    )
    settings = engine._settings(cfg)
    assert float(settings['MAP_TITLE_OFFSET'].rstrip('p')) >= 24.0
    assert engine._settings(replace(cfg, gmt_conf='MAP_TITLE_OFFSET=15p'))['MAP_TITLE_OFFSET'] == '15p'

    out = tmp_path / 'arctic.png'
    engine.render(cfg, str(out))
    assert out.is_file() and out.stat().st_size > 1000
    with Image.open(out) as im:
        assert im.width >= 1700  # auto-boosted preview DPI for crisp polar display


def test_ps_symbols_and_adaptive_preview_dpi(engine, grids, tmp_path):
    assert '\\260' in engine._label('105.0°–125.0°') and '–' not in engine._label('105.0°–125.0°')
    cfg = replace(config(grids, title='Temp [105.0°–125.0°, 10.0°–25.0°]', colorbar_title='±10 °C', show_coast=False, preview=True), dpi=200)
    script = engine.generate_script(cfg)
    assert '\\260' in script
    restored = engine.parse_script_to_config(script, cfg)
    assert '105.0°-125.0°' in restored.title and '±10 °C' in restored.colorbar_title

    out = tmp_path / 'adaptive.png'
    res_cfg = engine.render(replace(cfg, projection='Q180/16c'), str(out))
    assert res_cfg.dpi == 200
    with Image.open(out) as im:
        assert im.width >= 1800


def test_cn_border_modes_and_script_roundtrip(engine, grids, tmp_path):
    border_dir = tmp_path / 'cn_borders'
    border_dir.mkdir()
    l1 = border_dir / 'CN-border-L1.gmt'
    la = border_dir / 'CN-border-La.gmt'
    sample_seg = '> China Border\n100 20\n120 20\n120 40\n'
    l1.write_text(sample_seg, encoding='utf-8')
    la.write_text(sample_seg, encoding='utf-8')

    assert engine.find_cn_border_file('l1', str(border_dir)) == str(l1.resolve())
    assert engine.find_cn_border_file('la', str(border_dir)) == str(la.resolve())

    cfg = replace(
        config(
            grids,
            border_mode='global_cn_la',
            border_pen='0.6p,red',
            cn_border_dir=str(border_dir),
            show_coast=False,
        ),
        region=(95, 130, 15, 45),
        projection='M14c',
    )
    script = engine.generate_script(cfg)
    assert 'CN-border-La.gmt' in script and '-N1/' in script
    restored = engine.parse_script_to_config(script, cfg)
    assert restored.border_mode == 'global_cn_la'
    assert restored.show_borders is True
    assert restored.border_pen == '0.6p,red'

    out = tmp_path / 'cn_border.png'
    engine.render(cfg, str(out))
    assert out.is_file() and out.stat().st_size > 1000


def test_install_cn_border_from_zip(tmp_path):
    import zipfile
    from graticule.backend.gmt_engine import GMTEngine

    zip_path = tmp_path / 'china-geospatial-data-UTF8.zip'
    with zipfile.ZipFile(zip_path, 'w') as zf:
        zf.writestr('china-geospatial-data/CN-border-L1.gmt', '# L1\n>\n100 30\n101 31\n')
        zf.writestr('china-geospatial-data/CN-border-La.gmt', '# La\n>\n100 30\n101 31\n')
        zf.writestr('china-geospatial-data/ten-dash-line.gmt', '# 10-dash\n>\n110 15\n112 16\n')
        zf.writestr('china-geospatial-data/README.txt', 'ignore me')

    dest = tmp_path / 'installed_cn'
    status = GMTEngine.install_cn_border_from_zip(str(zip_path), str(dest))
    assert status['installed'] is True
    assert (dest / 'CN-border-L1.gmt').is_file()
    assert (dest / 'CN-border-La.gmt').is_file()
    assert (dest / 'ten-dash-line.gmt').is_file()
    assert not (dest / 'README.txt').exists()


def test_npz_multishape_cartesian_and_geographic_render(engine, tmp_path):
    import numpy as np
    from graticule.backend.nc_reader import NetCDFMetadataReader as Reader

    # Multi-shape coordinate-less NPZ (mirrors real task_00.npz layout)
    multi_npz = tmp_path / 'cutout_task.npz'
    z_0 = np.linspace(-5000, -500, 48 * 72, dtype=np.int16).reshape(48, 72)
    t_0 = np.linspace(10, 40, 32 * 32, dtype=np.int8).reshape(32, 32)
    np.savez(multi_npz, z_0=z_0, t_0=t_0)

    meta = Reader.open(str(multi_npz))
    assert meta.file_path == str(multi_npz.resolve())
    assert meta.variables['z_0'].is_2d_plotable and meta.variables['t_0'].is_2d_plotable
    assert not meta.variables['z_0'].is_geographic

    for vname in ('z_0', 't_0'):
        var = meta.variables[vname]
        spec = Reader.build_gmt_grid_spec(str(multi_npz), var, {})
        out = tmp_path / f'{vname}.png'
        cfg = PlotConfig(
            grid_spec=spec,
            source_path=str(multi_npz),
            variable_name=vname,
            projection='X12c/8c',
            is_geographic=False,
            show_coast=False,
            dpi=72,
        )
        engine.render(cfg, str(out))
        assert out.is_file() and out.stat().st_size > 1000

    # Geographic NPZ with 2D uniform meshgrid coordinates
    geo_npz = tmp_path / 'geo_mesh.npz'
    lon1d = np.linspace(100.0, 130.0, 31)
    lat1d = np.linspace(10.0, 40.0, 25)
    lon2d, lat2d = np.meshgrid(lon1d, lat1d)
    sst = (25.0 + np.sin(np.deg2rad(lat2d)) * np.cos(np.deg2rad(lon2d))).astype(np.float32)
    np.savez(geo_npz, lon=lon2d, lat=lat2d, sst=sst)

    geo_meta = Reader.open(str(geo_npz))
    assert geo_meta.variables['sst'].is_2d_plotable
    assert geo_meta.variables['sst'].is_geographic
    assert 'lon' not in geo_meta.variables and 'lat' not in geo_meta.variables
    geo_spec = Reader.build_gmt_grid_spec(str(geo_npz), geo_meta.variables['sst'], {})
    geo_out = tmp_path / 'geo_sst.png'
    engine.render(
        PlotConfig(
            grid_spec=geo_spec,
            source_path=str(geo_npz),
            variable_name='sst',
            projection='M12c',
            is_geographic=True,
            show_coast=False,
            dpi=72,
        ),
        str(geo_out),
    )
    assert geo_out.is_file() and geo_out.stat().st_size > 1000


def test_child_path_macports_and_minimal_env_render(engine, grids, tmp_path, monkeypatch):
    from graticule.backend.gmt_engine import GMTEngine

    fake = object.__new__(GMTEngine)
    fake.gmt_bin = '/opt/local/lib/gmt6/bin/gmt'
    parts = fake.child_path('/usr/bin:/bin').split(os.pathsep)
    assert parts[0] == '/opt/local/lib/gmt6/bin'
    assert '/opt/local/bin' in parts
    assert '/opt/homebrew/bin' in parts
    assert '/usr/bin' in parts

    monkeypatch.setenv('PATH', '/usr/bin:/bin')
    out = tmp_path / 'minimal_path.png'
    engine.render(config(grids, show_coast=False), str(out))
    assert out.is_file() and out.stat().st_size > 1000


def test_panoply_palette_and_no_coolwarm(engine, grids, tmp_path):
    assert 'panoply' in engine.CPT_OPTIONS
    assert 'coolwarm' not in engine.CPT_OPTIONS
    out = tmp_path / 'panoply.png'
    engine.render(config(grids, cpt='panoply', show_coast=False), str(out))
    assert out.is_file() and out.stat().st_size > 1000


def test_pacific_centered_projection_0_360(engine, grids, tmp_path):
    out = tmp_path / 'pacific.png'
    cfg = replace(
        config(grids, show_coast=False),
        region=(0.0, 360.0, -90.0, 90.0),
        projection='W180/16c',
    )
    engine.render(cfg, str(out))
    assert out.is_file() and out.stat().st_size > 1000


def test_categorical_flag_values_detection_and_render(engine, tmp_path):
    import netCDF4
    from graticule.backend.nc_reader import NetCDFMetadataReader as Reader

    nc_path = tmp_path / 'tid_flags.nc'
    lon = np.linspace(-180.0, 180.0, 37)
    lat = np.linspace(-90.0, 90.0, 19)
    flags = np.array([0, 10, 11, 40, 41, 70], dtype=np.int16)
    data = np.tile(flags, (19, 7))[:, :37]

    with netCDF4.Dataset(nc_path, 'w', format='NETCDF4') as ds:
        ds.createDimension('lon', lon.size)
        ds.createDimension('lat', lat.size)
        x = ds.createVariable('lon', 'f8', ('lon',))
        x[:] = lon
        x.units = 'degrees_east'
        y = ds.createVariable('lat', 'f8', ('lat',))
        y[:] = lat
        y.units = 'degrees_north'
        v = ds.createVariable('tid', 'i2', ('lat', 'lon'))
        v[:] = data
        v.long_name = 'Type Identifier'
        v.flag_values = flags
        v.flag_meanings = 'Land Singlebeam Multibeam Predicted Interpolated PreGenerated'

    meta = Reader.open(str(nc_path))
    var = meta.variables['tid']
    assert var.is_categorical is True
    assert var.flag_values == [0.0, 10.0, 11.0, 40.0, 41.0, 70.0]
    assert var.flag_meanings[0] == 'Land'

    spec = Reader.build_gmt_grid_spec(str(nc_path), var, {})
    cfg = PlotConfig(
        grid_spec=spec,
        source_path=str(nc_path),
        variable_name='tid',
        projection='Q14c',
        cpt='categorical',
        cpt_continuous=False,
        cpt_categorical=True,
        flag_values=tuple(var.flag_values),
        flag_meanings=tuple(var.flag_meanings),
        interpolation='n',
        show_coast=False,
        dpi=72,
    )
    out = tmp_path / 'tid_cat.png'
    engine.render(cfg, str(out))
    assert out.is_file() and out.stat().st_size > 1000

    script = engine.generate_script(cfg)
    assert 'categorical.cpt' in script and '# CATEGORICAL' in script and 'gmt makecpt' not in script
    restored = engine.parse_script_to_config(script, cfg)
    assert restored.cpt_categorical is True
    assert list(restored.flag_values) == [0.0, 10.0, 11.0, 40.0, 41.0, 70.0]
