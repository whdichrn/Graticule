import numpy as np
import pytest
import xarray as xr
from graticule.backend.nc_reader import NetCDFMetadataReader as Reader


def test_cf_axes_and_spatial_metadata_do_not_expand_to_lists(grids):
    meta = Reader.open(str(grids[1]))
    var = meta.variables['temp']
    assert (var.x_dim,var.y_dim,var.slice_dims) == ('lon','lat',['time','depth'])
    assert set(meta.dimension_coords) == {'time','depth'}
    assert var.is_geographic


def test_hyperslab_matches_selected_4d_slice(engine, grids):
    meta = Reader.open(str(grids[1])); var = meta.variables['temp']
    spec = Reader.build_gmt_grid_spec(meta.file_path,var,{'time':1,'depth':2})
    assert spec.endswith('?temp[1,2]')
    info = engine.get_grid_info(spec)
    assert (info['z_min'],info['z_max']) == (585,701)

@pytest.mark.parametrize('slices',[{'time':-1},{'time':2},{'unknown':0}])
def test_bad_slice_rejected(grids,slices):
    meta=Reader.open(str(grids[1]))
    with pytest.raises(ValueError): Reader.build_gmt_grid_spec(meta.file_path,meta.variables['temp'],slices)


def test_cf_axes_with_unusual_names(tmp_path):
    path=tmp_path/'cf.nc'
    xr.Dataset({'field':(('row','col'),np.zeros((3,4)))},coords={
        'col':('col',np.arange(4),{'axis':'X','standard_name':'longitude','units':'degrees_east'}),
        'row':('row',np.arange(3),{'axis':'Y','standard_name':'latitude','units':'degrees_north'})}).to_netcdf(path)
    v=Reader.open(str(path)).variables['field']
    assert v.is_2d_plotable and v.is_geographic and v.x_dim=='col' and v.y_dim=='row'

@pytest.mark.parametrize('kind',['irregular','curvilinear','transposed','nonnumeric'])
def test_unsupported_geometry_is_explained(tmp_path,kind):
    path=tmp_path/'unsupported.nc'
    ds=xr.Dataset({'z':(('lat','lon'),np.ones((3,4)))},coords={'lat':[0,1,2],'lon':[1,2,3,4]})
    if kind=='irregular': ds=ds.assign_coords(lon=[1,2,4,8])
    if kind=='curvilinear': ds=ds.assign_coords(longitude=(('lat','lon'),np.zeros((3,4)),{'standard_name':'longitude'}))
    if kind=='transposed': ds=ds.transpose('lon','lat')
    if kind=='nonnumeric': ds['z']=(('lat','lon'),np.full((3,4),'text'))
    ds.to_netcdf(path); v=Reader.open(str(path)).variables['z']
    assert not v.is_2d_plotable
    if kind!='nonnumeric': assert v.unsupported_reason
