- emacs から LLM サーバを操作できる llm_chat_light モードを作って。
- comint を拡張する感じで、こちらからの入力と、
  LLM からの出力を良い感じに 1 つのバッファでやりとりします。
- なお、 LLM サーバは lm studio を利用します。ただし、将来別の LLM API にも対応できるように
  柔軟に作成して
- LLM サーバとの直接的なやりとりは python で行ない、 emacs は UI を担当します。

