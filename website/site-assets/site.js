'use strict';

const toggle = document.querySelector('.menu-toggle');
const navigation = document.querySelector('#navigation');
function closeMenu() {
  toggle.setAttribute('aria-expanded', 'false');
  toggle.setAttribute('aria-label', '展开导航');
  navigation.classList.remove('is-open');
}
toggle.addEventListener('click', () => {
  const expanded = toggle.getAttribute('aria-expanded') !== 'true';
  toggle.setAttribute('aria-expanded', String(expanded));
  toggle.setAttribute('aria-label', expanded ? '收起导航' : '展开导航');
  navigation.classList.toggle('is-open', expanded);
});
navigation.addEventListener('click', (event) => {
  if (event.target.closest('a')) closeMenu();
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && toggle.getAttribute('aria-expanded') === 'true') {
    closeMenu();
    toggle.focus();
  }
});

// 演示内容仅在浏览器中切换，不调用模型，不采集用户数据。
const scenarios = {
  think: {
    label: '思路整理', question: '想做的事太多，怎么安排这一周？',
    intro: '先给每件事找到一个合适的位置。',
    steps: ['列出本周真正想完成的三件事。', '区分“必须做”和“可以晚一点做”。', '留一些空白，让计划也能呼吸。'],
  },
  write: {
    label: '写作灵感', question: '想写一篇关于“慢下来”的文章，从哪儿落笔？',
    intro: '先从一个具体的生活片段开始。',
    steps: ['回想最近一次让你停下来的小事。', '写下那个场景的声音、气味和感受。', '最后再问：这件事让你重新看见了什么？'],
  },
  learn: {
    label: '阅读与知识', question: '读了很多资料，怎么把它们变成自己的理解？',
    intro: '把“读过”变成“能够说清楚”。',
    steps: ['用自己的话，概括每份资料的核心观点。', '找出它们相同、不同和相互补充的地方。', '回到一个真实问题，试着用这些观点回答。'],
  },
};
document.querySelectorAll('[data-scenario]').forEach((button) => {
  button.addEventListener('click', () => {
    const scenario = scenarios[button.dataset.scenario];
    document.querySelectorAll('[data-scenario]').forEach((item) => {
      const active = item === button;
      item.classList.toggle('active', active);
      item.setAttribute('aria-pressed', String(active));
    });
    document.querySelector('#scenario-label').textContent = scenario.label;
    document.querySelector('#demo-question').textContent = scenario.question;
    document.querySelector('#demo-intro').textContent = scenario.intro;
    scenario.steps.forEach((step, index) => {
      document.querySelector(`#demo-step-${index + 1}`).textContent = step;
    });
  });
});
