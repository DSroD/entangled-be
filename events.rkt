(module event racket

  (require (for-syntax syntax/parse
                       racket/syntax))

  (define event-bus (make-channel))
  (provide event-bus)
  
  ; Syntax for creating event objects tied to an event bus
  ; Syntactic sugar, literally...
  (define-syntax (event stx)
    (syntax-parse stx
      [(event name:id [values ...])
       (with-syntax* ([call-name (format-id #'name "call-~a" #'name)])
         #'(begin (struct name [values ...])
                  (define (call-name values ...)
                    (channel-put event-bus (name values ...)))
                    (provide call-name
                             (struct-out name))
                  ))]))


  ; event structs
  (event ws-init-session-event [conn])
  (event ws-leave-session-event [conn])
  (event ws-connect-to-session-event [conn sess-id])
  (event ws-session-msg-event [conn msg])
  (event timer-tick-event [name])
)

