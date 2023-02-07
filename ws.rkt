#lang racket
; https://github.com/tonyg/racket-rfc6455/blob/master/net/rfc6455/examples/echo-server.rkt
(require net/rfc6455)

(require (for-syntax syntax/parse
                     racket/syntax))

(define max-sessions 512)
(define key-change-interval 1)
(define idle-timeout 120)
(define port 8081)

(define event-bus (make-channel))

; Syntax for creating event objects tied to an event bus
; Syntactic sugar, literally...
(define-syntax (event stx)
  (syntax-parse stx
    [(event event-bus name:id [values ...])
     (with-syntax* ([(list-name ...) (generate-temporaries #'(values ...))]
                    [call-name (format-id #'name "call-~a" #'name)])
       #'(begin (struct name [values ...])
                (define (call-name values ...)
                  (channel-put event-bus (name values ...)))))]))

(define-syntax-rule (hash-remove2 hash id1 id2)
  (hash-remove (hash-remove hash id1) id2))

; ---- párování konekcí ----
; Párování
; alice a bob jsou ws-connection
(struct qm-pair [alice bob])

; App state
; sessions je (make-hash) integer -> ws-connection | qm-pair
; connections je (make-hasheq) ws-connection -> integer
(struct app-state [sessions connections])

; set int int -> int
; Vytvoření nového unikátního klíče
(define (create-key existing-keys min max)
  (let ([new-key (random min max)])
    (if (set-member? existing-keys new-key) (create-key)
        new-key)))

; Predikát určující dosáhnutí max. počtu sessions
(define (session-count-max? app-state)
  (>= (hash-count (app-state-sessions app-state))
         max-sessions))

; Events
; handlers have signature
; app-state event -> app-state                     

; event structs
(event event-bus ws-init-session-event [conn])
(event event-bus ws-leave-session-event [conn])
(event event-bus ws-connect-to-session-event [conn sess-id])
(event event-bus ws-session-msg-event [conn sess-id msg])
(event event-bus timer-tick-event [name])

; dispatcher
(define app-dispatcher
  (λ (state event)
    (cond [(ws-init-session-event? event) (handle-ws-init-session-event state event)]
          [(ws-leave-session-event? event) (handle-ws-leave-session-event state event)]
          [(ws-connect-to-session-event? event) (handle-ws-connect-to-session-event state event)]
          [(ws-session-msg-event? event) (handle-ws-session-msg-event state event)]
          [(timer-tick-event? event) (handle-timer-tick-event state event)]
          )))

; handlers
; initialize session
(define (handle-ws-init-session-event state ev)
  (let ([conn (ws-init-session-event-conn ev)]
        [sessions (app-state-sessions state)]
        [connections (app-state-connections state)])
    (cond [(session-count-max? state) (begin (ws-send! conn "sessions-full") ; full sessions
                                             state)]
          [(hash-has-key? connections conn) (begin (ws-send! conn "already-in-session") ; already in some session
                                                               state)]
          [else (let ([new-key (create-key (list->set (hash-keys sessions)) 10000 99999)])
                  (begin (ws-send! conn (number->string new-key))
                         (app-state (hash-set sessions new-key conn) (hash-set connections conn new-key))))]
          )))
; leave session
(define (handle-ws-leave-session-event state ev)
  (let ([conn (ws-leave-session-event-conn ev)]
        [sess (app-state-sessions state)]
        [s-conns (app-state-connections state)])
    (cond [(not (hash-has-key? s-conns conn)) (begin (ws-send! conn "no-session")
                                                     state)]
          [else (let* ([cs-id (hash-ref s-conns conn)]
                       [cs (hash-ref sess cs-id)])
                  (cond [(qm-pair? cs) (begin (ws-send! (qm-pair-alice cs) "leave!")
                                              (ws-send! (qm-pair-bob cs) "leave!")
                                              (app-state (hash-remove sess cs-id)
                                                         (hash-remove2 s-conns
                                                                       (qm-pair-alice cs)
                                                                       (qm-pair-bob cs))))]
                        [(ws-conn? cs) (begin (ws-send! cs "leave!")
                                              (app-state (hash-remove sess cs-id)
                                                         (hash-remove s-conns cs)))]
                        [else (begin (ws-send! conn "err")
                                     state)]))])))

(define (handle-ws-connect-to-session-event state ev)
  state)

(define (handle-ws-session-msg-event state ev)
  state)

(define (handle-timer-tick-event state ev)
  state)

; websockets handling
(define (websocket-service event-bus)

  (define ws-ch (make-channel))
  
  (define (ws-dispatcher msg conn)
    (match msg
      ["init-session"
       (call-ws-init-session-event conn)]
      ["leave-session"
       (call-ws-leave-session-event conn)]
      [(regexp #px"join-session ([1-9][0-9]{4})" (list _ num))
       (call-ws-connect-to-session-event conn (string->number num))]
      [_ (printf "received unknown msg ~a\n" msg)]))
  
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
  (ws-serve #:port port ws-handler)
  ws-ch)

  
(define (main)
  (define ws-service (websocket-service event-bus))

  (let loop ([as (app-state (hash)(hasheq))])
    (let ([rec-event (channel-get event-bus)])
      (loop (app-dispatcher as rec-event)))))
      