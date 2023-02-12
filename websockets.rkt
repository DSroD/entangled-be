(module websockets racket
  (require "events.rkt"
           net/rfc6455)
  
  (define ws-ch (make-channel))
  (provide ws-ch
           websocket-service)

  ; websocket dispatcher
  (define (ws-dispatcher msg conn)
    (match msg
      ["init-session"
       (call-ws-init-session-event conn)]
      ["leave-session"
       (call-ws-leave-session-event conn)]
      [(regexp #px"join-session ([1-9][0-9]{4})" (list _ num))
       (call-ws-connect-to-session-event conn (string->number num))]
      [(regexp #px"msg (.+)" (list _ msg))
       (call-ws-session-msg-event conn msg)]
      [_ (printf "received unknown msg ~a\n" msg)]))

  ; handler loop
  (define (ws-handler conn state)
    (let loop ()
      (sync (handle-evt (ws-recv-evt conn #:payload-type 'text)
                        (λ (msg)
                          (unless (eof-object? msg)
                            (ws-dispatcher msg conn)
                            (loop))))
            (handle-evt ws-ch
                        (λ (msg)
                          (cond [(eq? msg 'exit) (ws-close! conn)]
                                [else (loop)]))))))

  ; serve websockets
  (define (websocket-service event-bus port)
    (ws-serve #:port port ws-handler) ws-ch)
  
)