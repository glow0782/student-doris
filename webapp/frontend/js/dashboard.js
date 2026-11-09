/* =============================================================
 * 数据大屏（Vue3 + ECharts）
 * 页面加载自动拉取 /api/chart/* 两个 Doris 统计接口；
 * 提供手动「刷新数据」按钮 + 可选的 30 秒自动刷新开关。
 * ============================================================= */
(function () {
  var createApp = Vue.createApp;
  var ref = Vue.ref, onMounted = Vue.onMounted,
      onUnmounted = Vue.onUnmounted, watch = Vue.watch;

  var classChart = null, genderChart = null, timer = null;

  function stamp() {
    var d = new Date();
    function p(n) { return n < 10 ? '0' + n : '' + n; }
    return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }

  createApp({
    setup: function () {
      var loading = ref(false);
      var error = ref('');
      var updatedAt = ref('');
      var total = ref(0);
      var classCount = ref(0);
      var autoRefresh = ref(false);

      function renderClass(data) {
        var n = data.categories.length;
        var visible = 15;
        var endPct = n > visible ? Math.round(visible / n * 100) : 100;
        classChart.setOption({
          grid: { left: 46, right: 18, top: 22, bottom: 84 },
          tooltip: { trigger: 'axis', axisPointer: { type: 'shadow' } },
          xAxis: {
            type: 'category',
            data: data.categories,
            axisLabel: { interval: 0, rotate: 40, color: '#5a6678', fontSize: 11 },
            axisLine: { lineStyle: { color: '#c9d0da' } }
          },
          yAxis: {
            type: 'value', minInterval: 1,
            splitLine: { lineStyle: { color: '#e8eaed', width: 1, type: 'solid' } },
            axisLabel: { color: '#5a6678' }
          },
          dataZoom: n > visible ? [
            {
              type: 'slider', xAxisIndex: 0, start: 0, end: endPct,
              bottom: 8, height: 18, borderColor: '#dde3ec',
              fillerColor: 'rgba(47,111,235,.12)', handleStyle: { color: '#2f6feb' },
              textStyle: { color: '#8a94a3', fontSize: 11 }
            },
            { type: 'inside', xAxisIndex: 0, start: 0, end: endPct }
          ] : [],
          series: [{
            type: 'bar', data: data.values, barMaxWidth: 46,
            itemStyle: { color: '#2f6feb' },
            label: { show: true, position: 'top', color: '#25303f', fontSize: 11 }
          }]
        }, true);
      }

      function renderGender(data) {
        var items = data.items.map(function (i) {
          return {
            name: i.name, value: i.value,
            itemStyle: { color: i.name === '男' ? '#2f6feb' : '#d47aa0' }
          };
        });
        genderChart.setOption({
          tooltip: { trigger: 'item', formatter: '{b}: {c} 人 ({d}%)' },
          legend: { bottom: 6, textStyle: { color: '#5a6678' } },
          series: [{
            type: 'pie', radius: ['42%', '66%'], center: ['50%', '46%'],
            data: items,
            itemStyle: { borderColor: '#fff', borderWidth: 2 },
            label: { formatter: '{b}: {c}', color: '#25303f' }
          }]
        }, true);
      }

      async function refresh() {
        loading.value = true;
        error.value = '';
        try {
          var res = await Promise.all([API.classChart(), API.genderChart()]);
          renderClass(res[0]);
          renderGender(res[1]);
          total.value = res[0].total;
          classCount.value = res[0].items.length;
          updatedAt.value = stamp();
        } catch (e) {
          error.value = '统计接口异常：' + e.message;
        } finally {
          loading.value = false;
        }
      }

      function resize() {
        if (classChart) classChart.resize();
        if (genderChart) genderChart.resize();
      }

      watch(autoRefresh, function (v) {
        if (timer) { clearInterval(timer); timer = null; }
        if (v) { timer = setInterval(refresh, 30000); }
      });

      onMounted(function () {
        classChart = echarts.init(document.getElementById('classChart'));
        genderChart = echarts.init(document.getElementById('genderChart'));
        window.addEventListener('resize', resize);
        refresh();                       // 页面加载自动拉取
      });

      onUnmounted(function () {
        if (timer) clearInterval(timer);
        window.removeEventListener('resize', resize);
      });

      return {
        loading: loading, error: error, updatedAt: updatedAt,
        total: total, classCount: classCount, autoRefresh: autoRefresh,
        refresh: refresh
      };
    }
  }).mount('#app');
})();
