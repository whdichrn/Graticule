import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
import numpy as np
import pytest
import xarray as xr
from PySide6 import QtWidgets
from graticule.backend.gmt_engine import GMTEngine

@pytest.fixture(scope='session')
def app():
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

@pytest.fixture(scope='session')
def engine():
    if not GMTEngine._find_gmt(): pytest.skip('GMT 6 is required for integration tests')
    engine = GMTEngine()
    yield engine
    engine.close()

@pytest.fixture
def grids(tmp_path):
    lon = np.linspace(0, 360, 73)
    lat = np.linspace(-90, 90, 37)
    values = np.cos(np.deg2rad(lat[:, None]))*np.sin(np.deg2rad(lon[None, :]))
    global_path = tmp_path/'global data.nc'
    xr.Dataset({'field':(('lat','lon'),values,{'units':'mGal'})}, coords={'lon':lon,'lat':lat}).to_netcdf(global_path)
    regional = tmp_path/'regional.nc'
    values = np.arange(2*3*9*13,dtype=float).reshape(2,3,9,13)
    xr.Dataset({'temp':(('time','depth','lat','lon'),values)},coords={'time':[0,1],'depth':[10,20,30], 'lat':np.linspace(20,40,9),'lon':np.linspace(100,130,13)}).to_netcdf(regional)
    return global_path, regional
