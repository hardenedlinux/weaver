;;; Yuanxu owns discovery, selection, admission and generation currentness.
(import :yuanxu/module-system/selection/init-syntax)
(yuanxu!
  :load-modules "./scheme" mode: explicit rename: Weaver
  (governance)
  (policy)
  (gateway))
