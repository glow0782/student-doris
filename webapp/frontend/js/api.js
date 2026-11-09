/* =============================================================
 * axios 统一封装
 *
 * 默认：同源 /api，由 nginx 反代到 flask:8000（浏览器只访问 8081，零跨域）。
 * 可选：如需直连后端 8000 调试（此时 Flask 的 CORS 生效），在引入本文件前设置：
 *   window.APP_CONFIG = { API_BASE: 'http://<host-ip>:8000' };
 *
 * 响应拦截器统一拆掉 {"code":0,"msg":"ok","data":...} 外壳，
 * 调用方直接拿到 data；失败统一抛 Error(msg)。
 * ============================================================= */
(function () {
  var base = (window.APP_CONFIG && window.APP_CONFIG.API_BASE) || '';

  var http = axios.create({
    baseURL: base + '/api',
    timeout: 15000,
    headers: { 'Content-Type': 'application/json' }
  });

  http.interceptors.response.use(
    function (res) {
      var body = res.data;
      if (body && body.code === 0) return body.data;
      return Promise.reject(new Error((body && body.msg) || '接口返回异常'));
    },
    function (err) {
      var msg = (err.response && err.response.data && err.response.data.msg)
        || err.message || '网络请求失败';
      return Promise.reject(new Error(msg));
    }
  );

  window.API = {
    // 健康检查
    health: function () { return http.get('/health'); },

    // 班级维表 + 学生 CRUD -> Flask -> MySQL student_management
    listClasses: function () { return http.get('/student/classes'); },
    listStudents: function (keyword, page, size) {
      return http.get('/student/list', {
        params: { keyword: keyword || '', page: page || 1, size: size || 50 }
      });
    },
    addStudent: function (data) { return http.post('/student/add', data); },
    updateStudent: function (id, data) { return http.put('/student/update/' + id, data); },
    deleteStudent: function (id) { return http.delete('/student/delete/' + id); },

    // 统计图表 -> Flask -> Doris student_sync（已有的 DWD / ADS 表）
    classChart: function () { return http.get('/chart/class'); },
    genderChart: function () { return http.get('/chart/gender'); }
  };
})();
