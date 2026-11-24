from dataclasses import replace
import time
import numpy as np
from PySide6 import QtCore,QtWidgets,QtTest
from graticule.backend.nc_reader import NetCDFMetadataReader as Reader
from graticule.backend.gmt_engine import PlotConfig
from graticule.ui.control_panel import ControlPanel
from graticule.ui.interactive_canvas import InteractiveCanvas
from graticule.ui.plot_tab_view import PlotTabView
from graticule.ui.main_window import MainWindow


def settle(app,window,timeout=20):
    start=time.monotonic()
    while window._workers or window._pending:
        app.processEvents();time.sleep(.01)
        assert time.monotonic()-start<timeout
    app.processEvents()


def test_manual_projection_and_all_settings_survive_sync(app,grids):
    meta=Reader.open(str(grids[1]));panel=ControlPanel();panel.set_dataset(meta);panel.set_variable(meta.variables['temp'])
    cfg=PlotConfig(Reader.build_gmt_grid_spec(meta.file_path,meta.variables['temp'],{'time':1,'depth':2}),region=(100,130,20,40),projection='M18c',source_path=meta.file_path,variable_name='temp',slice_indices={'time':1,'depth':2},cpt='blue,red',title='',colorbar_title='custom',mask_color='white',dpi=220,show_grid=False,title_size=17,makecpt_args='-D',colorbar_args='-Bxa1')
    panel.sync_from_config(cfg)
    restored=panel.get_plot_config()
    assert restored==cfg
    panel.set_region(105,120,22,35)
    assert panel.get_plot_config().projection=='M18c'
    panel.chk_auto_projection.setChecked(True)
    assert panel.get_plot_config().projection_mode=='auto' and panel.get_plot_config().projection!='M18c'


def test_multiple_datasets_restore_correct_source_and_slice(app,engine,grids):
    w=MainWindow();w.show()
    errors=[];w._on_render_error=lambda *args: errors.append(args[-1])
    w.open_file(str(grids[0]));w.open_file(str(grids[1]));settle(app,w)
    assert not errors
    assert w.dataset_tree.tree.topLevelItemCount()==2 and w.plot_tabs.count()==2
    regional=w.get_active_tab_view();p=w.control_panel
    p._slice_widgets['time'][1].setValue(1);p._slice_widgets['depth'][1].setValue(2);p.trigger_render();settle(app,w)
    w.plot_tabs.setCurrentIndex(0)
    assert w.control_panel.get_plot_config().source_path==str(grids[0])
    w.plot_tabs.setCurrentIndex(1)
    cfg=w.control_panel.get_plot_config()
    assert cfg.source_path==str(grids[1]) and cfg.grid_spec.endswith('[1,2]') and cfg.slice_indices=={'time':1,'depth':2}
    w._close_dataset(w.datasets[str(grids[0])]);assert w.plot_tabs.count()==1 and len(w.datasets)==1
    w.close()


def test_render_queue_is_bounded_and_newest_request_wins(app,grids):
    w=MainWindow();w.show();errors=[];w._on_render_error=lambda *args: errors.append(args[-1])
    w.open_file(str(grids[0]));tab=w.get_active_tab_view()
    for i in range(8): w._render_tab(tab,replace(tab.config,title=f'request {i}',projection='Q180/16c',projection_mode='manual'))
    assert len(w._workers)<=2 and len(w._pending)<=1
    settle(app,w);assert not errors and tab.display_config.title=='request 7'
    # Closing a tab with active work must not deliver to a deleted QWidget.
    w._render_tab(tab,replace(tab.config,title='closing'));w._on_tab_close_requested(0);settle(app,w)
    assert w.plot_tabs.count()==0
    w.close()


def test_selection_uses_curved_geometry_and_handles_pole(app,engine):
    c=InteractiveCanvas();c.engine=engine;c.geo_region=(0,360,60,90);c.projection='S0/90/15c';c.map_dims_cm=(15,15)
    r=c.selection_region(.4,.4,.6,.6)
    assert r and r[0]==0 and r[1]==360 and r[3]>89.99
    c.geo_region=(0,360,-90,90);c.projection='W180/16c';c.map_dims_cm=(16,8)
    assert c.selection_region(0,.95,.03,1) is None
    r=c.selection_region(.4,.4,.6,.6)
    assert r and r[0]<180<r[1] and r[2]<0<r[3]


def test_child_inherits_style_and_switches_interrupted_to_regional(app):
    cfg=PlotConfig('file.nc?z',region=(0,360,-90,90),projection='IntMollOcean',projection_mode='manual',source_path='file.nc',variable_name='z',title_size=18,makecpt_args='-D')
    tab=PlotTabView('test',cfg);spy=QtTest.QSignalSpy(tab.spawn_subregion_tab)
    tab._on_box_selected(100,120,20,40);child=spy.at(0)[0]
    assert child.projection!='IntMollOcean' and child.projection_mode=='auto'
    assert child.source_path==cfg.source_path and child.title_size==18 and child.makecpt_args=='-D'


def test_close_waits_for_running_workers_without_destroying_threads(app,grids):
    w=MainWindow();w.show();w.open_file(str(grids[0]));w.close()
    assert w._closing
    settle(app,w)
    assert not w.isVisible()


def test_custom_script_execution_is_async_and_preview_is_readable(app,grids,monkeypatch):
    from graticule.ui.main_window import ScriptEditorDialog
    from PySide6 import QtGui
    messages=[]
    for method in ('critical','warning','information'):
        monkeypatch.setattr(QtWidgets.QMessageBox,method,lambda *args,**kw: messages.append(args[2]))
    w=MainWindow();w.show();w.open_file(str(grids[0]));settle(app,w)
    cfg=w.get_active_tab_view().config
    dialog=ScriptEditorDialog(w.engine.generate_script(cfg),cfg,w.engine,w)
    dialog.show();dialog._on_run_script()
    assert not dialog.btn_run.isEnabled()
    start=time.monotonic()
    while not dialog.btn_run.isEnabled():
        app.processEvents();time.sleep(.01)
        assert time.monotonic()-start<20
    assert not messages,messages
    assert dialog.custom_render_path and not QtGui.QImage(dialog.custom_render_path).isNull()
    dialog.close();w.close()


def test_selecting_another_dataset_root_cannot_mix_variable_and_file(app,grids):
    w=MainWindow();w.show();w.open_file(str(grids[0]));w.open_file(str(grids[1]));settle(app,w)
    w.dataset_tree.tree.setCurrentItem(w.dataset_tree._roots[str(grids[0])]);app.processEvents()
    assert w.control_panel.get_plot_config() is None
    assert not w.control_panel.btn_apply.isEnabled()
    w.plot_tabs.setCurrentIndex(0)
    assert w.control_panel.get_plot_config().variable_name=='field'
    assert w.dataset_tree.prop_table.item(0,1).text()=='field'
    w.close()
