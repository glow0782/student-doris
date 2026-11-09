/* =============================================================
 * 学生管理页（Vue3 全局构建版）
 * 数据源：MySQL student_management.student（已有数仓源表，CDC 会捕获变更）
 * 所有请求统一走 js/api.js 的 axios 封装
 * ============================================================= */
(function () {
  var createApp = Vue.createApp;
  var ref = Vue.ref, reactive = Vue.reactive, computed = Vue.computed,
      onMounted = Vue.onMounted;

  function today() {
    var d = new Date();
    function p(n) { return n < 10 ? '0' + n : '' + n; }
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
  }

  function emptyForm() {
    return {
      student_no: '', name: '', gender: '男', class_id: '',
      enroll_date: today(), status: '在读', phone: '', email: ''
    };
  }

  createApp({
    setup: function () {
      var list = ref([]);
      var classes = ref([]);
      var total = ref(0);
      var page = ref(1);
      var size = ref(50);
      var keyword = ref('');
      var loading = ref(false);
      var error = ref('');
      var notice = ref('');
      var form = reactive(emptyForm());
      var dialog = reactive({
        show: false, mode: 'add', id: null, error: '', saving: false
      });

      var pageCount = computed(function () {
        return Math.max(1, Math.ceil(total.value / size.value));
      });

      async function loadClasses() {
        try {
          var data = await API.listClasses();
          classes.value = data.list;
        } catch (e) {
          error.value = '班级列表加载失败：' + e.message;
        }
      }

      async function load(p) {
        if (p !== undefined) page.value = p;
        loading.value = true;
        error.value = '';
        try {
          var data = await API.listStudents(keyword.value, page.value, size.value);
          list.value = data.list;
          total.value = data.total;
          page.value = data.page;
        } catch (e) {
          error.value = e.message;
        } finally {
          loading.value = false;
        }
      }

      function go(p) {
        if (p < 1 || p > pageCount.value) return;
        load(p);
      }

      function resetAndLoad() { load(1); }
      function reset() { keyword.value = ''; load(1); }

      function openAdd() {
        Object.assign(form, emptyForm());
        dialog.mode = 'add';
        dialog.id = null;
        dialog.error = '';
        dialog.show = true;
      }

      function openEdit(row) {
        Object.assign(form, {
          student_no: row.student_no,
          name: row.name,
          gender: row.gender,
          class_id: row.class_id,
          enroll_date: row.enroll_date || today(),
          status: row.status || '在读',
          phone: row.phone || '',
          email: row.email || ''
        });
        dialog.mode = 'edit';
        dialog.id = row.id;
        dialog.error = '';
        dialog.show = true;
      }

      function closeDialog() { dialog.show = false; }

      async function submit() {
        if (!form.student_no || !form.name || !form.class_id || !form.enroll_date) {
          dialog.error = '学号、姓名、班级、入学日期为必填项';
          return;
        }
        dialog.saving = true;
        dialog.error = '';
        try {
          var payload = {
            student_no: form.student_no,
            name: form.name,
            gender: form.gender,
            class_id: Number(form.class_id),
            enroll_date: form.enroll_date,
            status: form.status,
            phone: form.phone,
            email: form.email
          };
          if (dialog.mode === 'add') {
            await API.addStudent(payload);
          } else {
            await API.updateStudent(dialog.id, payload);
          }
          dialog.show = false;
          notice.value = '已写入 student_management.student。SeaTunnel CDC 会同步到 ODS，'
            + 'DolphinScheduler 重跑分层后，到大屏点「刷新数据」即可看到变化。';
          await load(dialog.mode === 'add' ? 1 : page.value);
        } catch (e) {
          dialog.error = e.message;
        } finally {
          dialog.saving = false;
        }
      }

      async function remove(row) {
        var tip = '确认删除学生 ' + row.name + '（' + row.student_no + '）？\n\n'
          + '注意：enrollment 外键为 CASCADE，该生的选课/成绩记录会一并删除，'
          + '并由 CDC 同步到 Doris 数仓。此操作不可撤销。';
        if (!window.confirm(tip)) return;
        error.value = '';
        try {
          await API.deleteStudent(row.id);
          notice.value = '已从 student_management 删除，CDC 与分层作业会同步该变更。';
          await load(page.value);
        } catch (e) {
          error.value = e.message;
        }
      }

      onMounted(function () {
        loadClasses();
        load(1);
      });

      return {
        list: list, classes: classes, total: total, page: page, size: size,
        pageCount: pageCount, keyword: keyword, loading: loading,
        error: error, notice: notice, form: form, dialog: dialog,
        load: load, go: go, reset: reset, resetAndLoad: resetAndLoad,
        openAdd: openAdd, openEdit: openEdit, closeDialog: closeDialog,
        submit: submit, remove: remove
      };
    }
  }).mount('#app');
})();
