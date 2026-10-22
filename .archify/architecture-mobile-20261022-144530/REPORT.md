# 架构图交付记录

- diagram_type: architecture
- output: `mobile.html`
- source_revision: `62ed15366be138f0fc0daf85154cb27083130d30`
- specification_sha256: `dd35cc64fac6408c5a2e78d79cd1104d0217f5272f1610774176abcfa8034352`
- artifact_sha256: `45bc30839d6d043ba25f53997c14169b180342331697c8edad406f42cc99bae9`
- validation: 9/9 showcase, 0 errors, 0 warnings
- browser_evidence: passed
- visual_review: passed
- correction_rounds: 1

当前有效完成回执为 [review-3/mobile.finalize.json](review-3/mobile.finalize.json)，浏览器回执为 [review-3/mobile.browser-check.json](review-3/mobile.browser-check.json)。同目录较早回执仅保存生成过程；验证当前 HTML 时使用上述最终记录。

## 源码与关系复核

已按固定提交核对节点、主要调用/读写关系和平台边界。sources 指向提交内真实文件及行号，当前文档与图不声明未经观察的服务。

## 截图与感知复核

已查看 `visual-check/` 中 1440×900、2048×1320 的浅色和深色四张截图。2048×1320 可见所有图节点与图例；1440×900 通过页面纵向滚动继续阅读。未见节点互相覆盖、文字越框或标注覆盖节点。
默认比例下细节字号较小，深色主题的灰色关系说明偏淡，可使用查看器放大。截图不覆盖首屏之外的全部说明卡片，因此感知通过范围限于已捕获的图面；浏览器自动检查另行通过。

自动路由记录 5 处已桥接交叉，作为路线复杂度提示保留，不等同于来源或自动检查失败。

布局曾试调一次，但触发文字可读宽度门禁，已恢复原候选并重新完整生成；不把失败尝试作为通过记录。
