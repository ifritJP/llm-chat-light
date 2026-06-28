;;; llm-chat-light.el --- A light chat client for LLM using comint -*- lexical-binding: t; -*-

(defvar llm-chat-light-development-mode t
  "Non-nil means clean up all llm-chat-light- variable symbols on reload.")

(when llm-chat-light-development-mode
  (mapatoms
   (lambda (sym)
     (let ((name (symbol-name sym)))
       (when (and (string-prefix-p "llm-chat-light-" name)
                  (boundp sym)
                  (not (eq sym 'llm-chat-light-development-mode)))
         (makunbound sym))))))

(require 'comint)
(require 'ansi-color)
(require 'json)
(require 'tab-line nil t)

(defvar-local llm-chat-light-history nil
  "Lisp representation of the current session chat history.")

(defvar-local llm-chat-light-token-usage nil
  "String representing the last token usage to display in the mode-line.")

(defvar-local llm-chat-light-reasoning "none"
  "Buffer-local reasoning mode state (\\='none\\=', \\='off\\=', \\='low\\=', \\='medium\\=', \\='high\\=', \\='on\\=').")

(defun llm-chat-light-read-session (file)
  "Read JSON history from FILE."
  (if (file-exists-p file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (let ((json-array-type 'list)
                  (json-object-type 'alist)
                  (json-key-type 'symbol))
              (json-read)))
        (error nil))
    nil))

(defun llm-chat-light-write-session (file history)
  "Write HISTORY alist to FILE as JSON."
  (let ((json-encoding-pretty-print t))
    (with-temp-file file
      (insert (json-encode history)))))

;;; llm-chat-light.el ends here (comment wrapper: clean-assistant-response removed)

(defgroup llm-chat-light nil
  "Light chat client for LLM server."
  :group 'run)

(defface llm-chat-light-assistant
  '((((class color) (min-colors 88) (background dark)) :foreground "PaleGreen" :weight bold)
    (((class color) (min-colors 88) (background light)) :foreground "ForestGreen" :weight bold)
    (t :bold t))
  "Face for the LLM assistant responses."
  :group 'llm-chat-light)

(defface llm-chat-light-key-sequence
  '((((class color) (min-colors 88) (background dark)) :foreground "tomato" :weight bold)
    (((class color) (min-colors 88) (background light)) :foreground "tomato" :weight bold)
    (t :bold t))
  "Face for the LLM assistant responses."
  :group 'llm-chat-light)


(defcustom llm-chat-light-program "uv"
  "The program to run."
  :type 'string
  :group 'llm-chat-light)

(defcustom llm-chat-light-arguments '("run" "python" "-u" "src/chat_agent/cli.py")
  "List of arguments for the program."
  :type '(repeat string)
  :group 'llm-chat-light)

(defcustom llm-chat-light-api-base "http://localhost:1234/v1"
  "The API base URL for the LLM server."
  :type 'string
  :group 'llm-chat-light)

(defcustom llm-chat-light-model "unsloth/gemma-4-12b-it"
  "The model name to use."
  :type 'string
  :group 'llm-chat-light)

(defcustom llm-chat-light-default-reasoning "none"
  "The reasoning mode parameter (\\='none\\=', \\='off\\=', \\='low\\=', \\='medium\\=', \\='high\\=', \\='on\\=') sent to LM Studio."
  :type '(choice (const "none") (const "off") (const "low") (const "medium") (const "high") (const "on"))
  :group 'llm-chat-light)

(defcustom llm-chat-light-system-prompt "
From now on, responses should be in Japanese in principle.
Responses must be in plain-text, do not use Markdown or other syntax.
Do not reply with the first thought that comes to mind;
instead, think of three options internally and respond with the most appropriate one.
"
  "The system prompt defining global rules/instructions for the LLM."
  :type 'string
  :group 'llm-chat-light)

(defcustom llm-chat-light-session-directory (locate-user-emacs-file "llm-chat-light/session/")
  "Directory where session history files are saved.
If relative, resolved against the project root."
  :type 'directory
  :group 'llm-chat-light)

(defcustom llm-chat-light-session-file (locate-user-emacs-file "llm-chat-light/session/session.json")
  "Path to the file where session history is saved.
If relative, resolved against the project root."
  :type 'file
  :group 'llm-chat-light)

(defvar llm-chat-light-source-directory
  (cond (load-file-name (file-name-directory load-file-name))
        ((bound-and-true-p byte-compile-current-file) (file-name-directory byte-compile-current-file))
        (t (file-name-directory (or (buffer-file-name) default-directory))))
  "Directory where `llm-chat-light' source file is located.")

(defun llm-chat-light--project-root ()
  "Get the project root directory."
  (or (locate-dominating-file llm-chat-light-source-directory "pyproject.toml")
      llm-chat-light-source-directory))

(defun llm-chat-light--buffer-name (file)
  "Generate buffer name based on session FILE."
  (format "*llm-chat-light: %s*" (file-name-nondirectory file)))

(defun llm-chat-light--process-name (file)
  "Generate process name based on session FILE."
  (format "llm-chat-light: %s" (file-name-nondirectory file)))


(defvar llm-chat-light-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") 'llm-chat-light-interrupt)
    (define-key map (kbd "C-c C-s") 'llm-chat-light-switch-session)
    (define-key map (kbd "C-c C-d") 'llm-chat-light-delete-session)
    (define-key map (kbd "C-c C-m") 'llm-chat-light-change-model)
    (define-key map (kbd "C-c C-r") 'llm-chat-light-select-reasoning)
    (define-key map (kbd "RET") 'llm-chat-light-send-input)
    (define-key map (kbd "C-m") 'llm-chat-light-send-input)
    map)
  "Keymap for `llm-chat-light-mode'.")

(defun llm-chat-light-send-input ()
  "Send input to LLM process only if it's not empty or whitespace.
If cursor is in the middle of buffer (rest of buffer contains non-whitespace),
ignore the send action and insert a newline instead."
  (interactive)
  (let ((after-point (buffer-substring-no-properties (point) (point-max))))
    (if (not (string-match-p "\\`[ \t\n\r]*\\'" after-point))
	;; 無視して何もしない
        nil
      (let* ((proc (get-buffer-process (current-buffer)))
             (pmark (and proc (process-mark proc)))
             (start (or pmark (comint-line-beginning-position)))
             (end (point-max))
             (input (if (and start (<= start end))
                        (buffer-substring-no-properties start end)
                      "")))
        ;;(message "llm-chat-light-send-input: start=%s, end=%s, input=%S" start end input)
        (if (string-match-p "\\`[ \t\n\r]*\\'" input)
	    ;; 無視して何もしない
            nil
          (comint-send-input))))))

(defun llm-chat-light-interrupt ()
  "Confirm and interrupt the active LLM response generation."
  (interactive)
  (let ((proc (get-buffer-process (current-buffer))))
    (if (and proc (eq (process-status proc) 'run))
        (if (y-or-n-p "Interrupt the active LLM response generation? ")
            (progn
              (comint-interrupt-subjob)
              (message "LLM response generation interrupted."))
          (message "Interruption canceled."))
      (message "No active process is running."))))

(defun llm-chat-light-delete-session ()
  "Confirm and delete the current session JSON file, kill process, and buffer."
  (interactive)
  (let ((session-file llm-chat-light-session-file)
        (buf (current-buffer)))
    (if (and session-file (file-exists-p session-file))
        (if (y-or-n-p (format "Delete the current session file %s? " (file-name-nondirectory session-file)))
            (let ((proc (get-buffer-process buf)))
              ;; Kill process if active
              (when (and proc (eq (process-status proc) 'run))
                (delete-process proc))
              ;; Physically delete the file
              (delete-file session-file)
              (message "Session file %s deleted." (file-name-nondirectory session-file))
              ;; Close the buffer
              (kill-buffer buf))
          (message "Deletion canceled."))
      (message "No session file to delete."))))
(defun llm-chat-light-fetch-models ()
  "Fetch available models by running the python CLI with --list-models."
  (message "llm-chat-light-fetch-models: Starting (project-root: %s)" (llm-chat-light--project-root))
  (let* ((root (llm-chat-light--project-root))
         (default-directory root)
         (process-environment (copy-sequence process-environment)))
    (setenv "LLM_API_BASE" llm-chat-light-api-base)
    (message "llm-chat-light-fetch-models: Environment variable LLM_API_BASE=%s has been set." llm-chat-light-api-base)
    (let* ((cmd-args (append llm-chat-light-arguments '("--list-models")))
           (output (with-temp-buffer
                     (let ((coding-system-for-read 'utf-8))
                       (message "llm-chat-light-fetch-models: Starting process %s %S" llm-chat-light-program cmd-args)
                       (let ((exit-code (apply 'call-process llm-chat-light-program nil t nil cmd-args)))
                         (message "llm-chat-light-fetch-models: Process finished (ExitCode: %s)" exit-code)
                         (if (eq 0 exit-code)
                             (buffer-string)
                           (let ((err-out (buffer-string)))
                             (message "llm-chat-light-fetch-models: Error occurred - stdout/stderr: %s" err-out)
                             (error "Python CLI process terminated abnormally (code %s): %s" exit-code err-out)))))))
           (json-array-type 'list)
           (json-object-type 'alist)
           (json-key-type 'symbol))
      (message "llm-chat-light-fetch-models: Starting JSON parsing (characters to parse: %d)" (length output))
      (let ((parsed (json-read-from-string (string-trim output))))
        (message "llm-chat-light-fetch-models: JSON parsing completed (fetched models count: %d): %S" (length parsed) parsed)
        parsed))))

(defun llm-chat-light-change-model ()
  "Interactively switch the active model of the current session."
  (interactive)
  (message "llm-chat-light-change-model: Starting")
  (let ((proc (get-buffer-process (current-buffer))))
    (if (and proc (eq (process-status proc) 'run))
        (let* ((models (condition-case err
                           (llm-chat-light-fetch-models)
                         (error 
                          (let ((err-msg (error-message-string err)))
                            (message "llm-chat-light-change-model: Caught error while fetching models: %s" err-msg)
                            (user-error "Failed to connect to LM Studio: %s" err-msg))))))
          (message "llm-chat-light-change-model: Fetched models list: %S" models)
          (if (null models)
              (progn
                (message "llm-chat-light-change-model: The fetched models list is empty")
                (user-error "Could not fetch any valid models from LM Studio. Please check if models are loaded"))
            (let* ((current-model (or (and (boundp 'llm-chat-light-model) llm-chat-light-model) ""))
                   (prompt (format "Switch to model (default %s): " current-model))
                   (target (completing-read prompt models nil t nil nil current-model)))
              (message "llm-chat-light-change-model: Selected model: %s" target)
              (when (and target (not (string-empty-p target)))
                (message "llm-chat-light-change-model: Sending model change command to the process")
                (comint-send-string proc (format "/model %s\n" target))
                (setq llm-chat-light-model target)
                (message "Sent model switch request: %s" target)))))
      (progn
        (message "llm-chat-light-change-model: Error - No active process is running")
        (message "llm-chat-light-change-model: Current buffer process status: %S" (and proc (process-status proc)))
        (message "llm-chat-light-change-model: Current buffer: %s" (current-buffer))
        (user-error "No active chat process found")))))

(defun llm-chat-light-select-reasoning ()
  "Switch the reasoning mode parameter for the current LLM session."
  (interactive)
  (let ((proc (get-buffer-process (current-buffer))))
    (if (and proc (eq (process-status proc) 'run))
        (let* ((options '("none" "off" "low" "medium" "high" "on"))
               (collection (lambda (string pred action)
                             (if (eq action 'metadata)
                                 `(metadata (display-sort-function . ,#'identity)
                                            (cycle-sort-function . ,#'identity))
                               (complete-with-action action options string pred))))
               (prompt (format "Reasoning mode (default %s): " llm-chat-light-reasoning))
               (new-val (completing-read prompt collection nil t nil nil llm-chat-light-reasoning)))
          (when (and new-val (not (string-empty-p new-val)))
            (comint-send-string proc (format "/reasoning %s\n" new-val))
            (setq-local llm-chat-light-reasoning new-val)
            (message "Changed reasoning mode to %s." new-val)
            (force-mode-line-update)))
      (message "No active process is running."))))


(define-derived-mode llm-chat-light-mode comint-mode "LLM-Chat-Light"
  "Major mode for interacting with LLM Server via Python CLI."
  (setq-local comint-prompt-regexp "^\\(llm-chat\\|Assistant\\)> ")
  (setq-local comint-use-prompt-regexp t)
  (setq-local comint-process-echoes nil)
  (setq-local next-line-add-newlines t)
  ;; Configure scroll to follow output maximum
  (setq-local comint-scroll-show-maximum-output t)
  (setq-local comint-input-ring-file-name nil)
  ;; Enable ANSI color escape codes
  (ansi-color-for-comint-mode-on)
  ;; Use both tab-line-format and header-line-format to display 2-line header at the top
  (setq-local tab-line-format
              '(:eval (concat (propertize "[C-c C-s]" 'face 'llm-chat-light-key-sequence) " Switch Session / "
                              (propertize "[C-c C-m]" 'face 'llm-chat-light-key-sequence) " Change Model / "
                              (propertize "[C-c C-r]" 'face 'llm-chat-light-key-sequence) " Select Reasoning | "
                              (propertize "[C-c C-d]" 'face 'llm-chat-light-key-sequence) " Delete Session | "
                              (propertize "[C-c C-c]" 'face 'llm-chat-light-key-sequence) " Kill Request")))
  (when (fboundp 'tab-line-mode)
    (tab-line-mode 1)
    (face-remap-add-relative 'tab-line 'header-line))
  (setq-local header-line-format
              '(:eval (format "%s | Reasoning: %s | Active Model: %s"
			      (if llm-chat-light-token-usage
                                        (format " %s" llm-chat-light-token-usage)
                                      "")
			      llm-chat-light-reasoning
                              (or (and (boundp 'llm-chat-light-model) llm-chat-light-model) "None")
                              )))
  ;; Add filter hooks for token usage and assistant response colorization
  (add-hook 'comint-output-filter-functions 'llm-chat-light-filter-token-usage nil t)
  (add-hook 'comint-output-filter-functions 'llm-chat-light-filter-colorize-assistant nil t)
  )

(defun llm-chat-light-filter-token-usage (_string)
  "Filter out token usage output and update the mode-line."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (or comint-last-output-start (point-min)))
      (while (re-search-forward "\\[TokenUsage: \\([0-9]+\\), \\([0-9]+\\), \\([0-9]+\\)\\]\n?" nil t)
        (let* ((prompt-tokens (match-string 1))
               (completion-tokens (match-string 2))
               (total-tokens (match-string 3)))
          ;; Delete token usage display marker
          (delete-region (match-beginning 0) (match-end 0))
          ;; Update mode-line
          (setq llm-chat-light-token-usage
                (format "[Tokens:: P:%s C:%s T:%s]"
                        prompt-tokens completion-tokens total-tokens))
          (force-mode-line-update))))))

(defun llm-chat-light-filter-colorize-assistant (_string)
  "Colorize the assistant response in the comint buffer."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (beginning-of-line)
      (while (re-search-forward "^Assistant> " nil t)
        (let ((start (match-beginning 0))
              (end (point-max)))
          (save-excursion
            (when (re-search-forward "^\\(?:llm-chat\\|Assistant\\)> " nil t)
              (setq end (match-beginning 0))))
          (when (< start end)
            (message "llm-chat-light: colorizing assistant response from %d to %d" start end)
            (add-text-properties start end '(face llm-chat-light-assistant font-lock-face llm-chat-light-assistant)))
          (goto-char end))))))

(defun llm-chat-light-get-first-user-message (file)
  "Read FILE and return the content of the first `user' role message.
If no `user' message is found, or an error occurs, return a default string."
  (let ((history (llm-chat-light-read-session file))
        (found nil))
    (while (and history (not found))
      (let ((msg (car history)))
        (if (equal (cdr (assoc 'role msg)) "user")
            (setq found msg)
          (setq history (cdr history)))))
    (if found
        (let* ((content (cdr (assoc 'content found)))
               (single-line (replace-regexp-in-string "[\n\r]+" " " content)))
          (if (> (length single-line) 40)
              (concat (substring single-line 0 40) "...")
            single-line))
      "(No user message)")))

(defun llm-chat-light-select-session-from-list ()
  "Select a session file from existing JSON files in session directory.
Includes a '[New Session]' option at the top to create a new session."
  (let* ((root (or (locate-dominating-file llm-chat-light-source-directory "pyproject.toml")
                   llm-chat-light-source-directory))
         (dir (expand-file-name llm-chat-light-session-directory root))
         (_ (make-directory dir t))
         (files (and (file-directory-p dir) (directory-files dir nil "\\.json\\'")))
         (new-candidate '("[New Session] | Create a new chat session" . "NEW"))
         (file-candidates
          (mapcar (lambda (f)
                    (let* ((abs-path (expand-file-name f dir))
                           (first-msg (llm-chat-light-get-first-user-message abs-path))
                           (display-name (format "%s | %s" f first-msg)))
                          (cons display-name f)))
                  files))
         (candidates (cons new-candidate file-candidates))
         (selected (completing-read "Select session: " candidates nil t))
         (selected-value (cdr (assoc selected candidates))))
    (if (equal selected-value "NEW")
        (let* ((ts (format-time-string "%Y%m%d_%H%M%S"))
               (default-name (format "session_%s.json" ts))
               (default-path (expand-file-name default-name dir)))
          (read-file-name "New session file (JSON): " dir default-path nil default-name))
      (expand-file-name selected-value dir))))

;;;###autoload
(defun llm-chat-light-switch-session (&optional file)
  "Switch to LLM chat session FILE or select one interactively.
This will switch to the session's buffer, starting it if not already running."
  (interactive)
  (let* ((file (or file (llm-chat-light-select-session-from-list)))
         (root (llm-chat-light--project-root))
         (abs-file (expand-file-name file root)))
    (llm-chat-light-start abs-file)))

(defun llm-chat-light-start (file)
  "Internal function to start the llm-chat-light process and buffer for FILE."
  (let* ((root (llm-chat-light--project-root))
         (session-file (expand-file-name file root))
         (buf-name (llm-chat-light--buffer-name session-file))
         (proc-name (llm-chat-light--process-name session-file))
         (buffer (get-buffer-create buf-name))
         (process-environment (copy-sequence process-environment)))
    ;; Initialize/update the session file on the Emacs side before starting
    (let ((history (llm-chat-light-read-session session-file)))
      (if llm-chat-light-system-prompt
          (let ((clean-prompt (replace-regexp-in-string "\\`[ \t\n\r]*" "" (replace-regexp-in-string "[ \t\n\r]+\\'" "" llm-chat-light-system-prompt))))
            (unless (string-empty-p clean-prompt)
              (if (null history)
                  (setq history (list `((role . "system") (content . ,clean-prompt))))
                (if (not (eq (cdr (assoc 'role (car history))) 'system))
                    (setq history (cons `((role . "system") (content . ,clean-prompt)) history))
                  (setcar history `((role . "system") (content . ,clean-prompt))))))))
      (llm-chat-light-write-session session-file history))

    (setenv "LLM_API_BASE" llm-chat-light-api-base)
    (setenv "LLM_MODEL" llm-chat-light-model)
    (setenv "LLM_REASONING" llm-chat-light-default-reasoning)
    (setenv "LLM_SYSTEM_PROMPT" llm-chat-light-system-prompt)
    (setenv "LLM_SESSION_FILE" session-file)
    (setenv "PYTHONUNBUFFERED" "1")
    (with-current-buffer buffer
      (unless (comint-check-proc buffer)
        (let ((default-directory root))
          (apply 'make-comint-in-buffer
                 proc-name
                 buffer
                 llm-chat-light-program
                 nil
                 llm-chat-light-arguments)
          (llm-chat-light-mode)))
      (setq-local llm-chat-light-session-file session-file)
      (setq-local llm-chat-light-reasoning llm-chat-light-default-reasoning)
      (setq-local llm-chat-light-history (llm-chat-light-read-session session-file))
      (llm-chat-light-filter-colorize-assistant nil))
    (pop-to-buffer buffer)))

;;;###autoload
(defun llm-chat-light (&optional arg)
  "Start llm-chat-light session.
With a prefix argument ARG (e.g., C-u), prompt for a session file.
Without ARG, if current buffer is in `llm-chat-light-mode' and
has a running process, do nothing. Otherwise, prompt for a
session file and start/switch to it."
  (interactive "P")
  (let* ((active-p (and (derived-mode-p 'llm-chat-light-mode)
                        (let ((proc (get-buffer-process (current-buffer))))
                          (and proc (eq (process-status proc) 'run))))))
    (if (or arg (not active-p))
        (let* ((session-file (llm-chat-light-select-session-from-list))
               (root (llm-chat-light--project-root))
               (abs-file (expand-file-name session-file root)))
          (llm-chat-light-start abs-file))
      (message "Current session is active."))))

(provide 'llm-chat-light)
;;; llm-chat-light.el ends here
