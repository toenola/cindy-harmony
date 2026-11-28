// The vendor viewer is identical to the bundle used by Mobile. XML stays data.
window.mxLoadResources = false;
window.mxLoadStylesheets = false;
window.cindyDrawioRender = (xml, dark) => {
  const root = document.getElementById('root');
  root.replaceChildren();
  const diagram = document.createElement('div');
  diagram.className = 'mxgraph';
  root.append(diagram);
  try {
    diagram.setAttribute('data-mxgraph', JSON.stringify({
      xml, nav: true, resize: true, toolbar: 'zoom layers pages',
      'dark-mode': dark ? '1' : '0', 'check-visible-state': false,
    }));
    GraphViewer.createViewerForElement(diagram);
  } catch (_) {
    root.textContent = '无法预览此图表';
  }
};
