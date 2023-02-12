#lang racket

(require net/rfc6455
         "events.rkt"
         "websockets.rkt")

(define max-sessions 512)
(define key-change-interval 1)
(define idle-timeout 120)
(define port 8081)

(define-syntax-rule (hash-remove2 hash id1 id2)
  (hash-remove (hash-remove hash id1) id2))

; ---- párování konekcí ----
; Párování
; alice a bob jsou ws-connection
(struct qm-pair [alice bob])

; App state
; sessions je (make-hash) integer -> ws-connection | qm-pair
; connections je (make-hasheq) ws-connection -> integer
; Poznámka: sessions a connections odpovídají struktuře bimapy
(struct app-state [sessions connections])

; QOL selektory
(define (get-session-key session state)
  (hash-ref (app-state-connections state) session (λ () #f)))
(define (get-session key state)
  (hash-ref (app-state-sessions state) key (λ () #f)))

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

; dispatcher
(define app-dispatcher
  (λ (state event)
    (cond [(ws-init-session-event? event) (handle-ws-init-session-event state event)]
          [(ws-leave-session-event? event) (handle-ws-leave-session-event state event)]
          [(ws-connect-to-session-event? event) (handle-ws-connect-to-session-event state event)]
          [(ws-session-msg-event? event) (handle-ws-session-msg-event state event)]
          [(timer-tick-event? event) (handle-timer-tick-event state event)]
          )))


; ----- handlers -----

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
                         (app-state (hash-set sessions new-key conn)
                                    (hash-set connections conn new-key))))]
          )))

; leave session
(define (handle-ws-leave-session-event state ev)
  (let ([conn (ws-leave-session-event-conn ev)]
        [sess (app-state-sessions state)]
        [s-conns (app-state-connections state)])
          ; Not in any session
    (cond [(not (hash-has-key? s-conns conn)) (begin (ws-send! conn "no-session")
                                                     state)]
          [else (let* ([cs-id (hash-ref s-conns conn)]
                       [cs (hash-ref sess cs-id)])
                        ; Paired session
                  (cond [(qm-pair? cs) (begin (ws-send! (qm-pair-alice cs) "leave!")
                                              (ws-send! (qm-pair-bob cs) "leave!")
                                              (app-state (hash-remove sess cs-id)
                                                         (hash-remove2 s-conns
                                                                       (qm-pair-alice cs)
                                                                       (qm-pair-bob cs))))]
                        ; Unpaired session
                        [(ws-conn? cs) (begin (ws-send! cs "leave!")
                                              (app-state (hash-remove sess cs-id)
                                                         (hash-remove s-conns cs)))]
                        ; State is polluted (where my type system at)
                        [else (begin (ws-send! conn "err")
                                     state)]))])))

; join session using key
(define (handle-ws-connect-to-session-event state ev)
  (let ([conn (ws-connect-to-session-event-conn ev)]
        [sess-id (ws-connect-to-session-event-sess-id ev)]
        [sessions (app-state-sessions state)]
        [sess-conns (app-state-connections state)])
          ; Already in some session
    (cond [(hash-has-key? sess-conns conn) (begin (ws-send! conn "already-connected")
                                                state)]
          ; Session exists
          [(hash-has-key? sessions sess-id) (let ([s (hash-ref sessions sess-id)])
                                              (if (ws-conn? s) ; unpaired session
                                                  (begin (ws-send! s "paired")
                                                         (ws-send! conn "paired")
                                                         (app-state (hash-set sessions sess-id
                                                                              (qm-pair s conn))
                                                                    (hash-set sess-conns conn sess-id)))
                                                  (begin (ws-send! conn "session-full") ; paired session
                                                         state)))]
          ; Session not found
          [else (begin (ws-send! conn "session-not-found")
                       state)])))

(define (handle-ws-session-msg-event state ev)
  (let ([conn (ws-session-msg-event-conn ev)]
        [msg (ws-session-msg-event-msg ev)]
        [sessions (app-state-sessions state)]
        [sess-conns (app-state-connections state)])
    (cond [(hash-has-key? sess-conns conn) (let* ([sess-id (hash-ref sess-conns conn)]
                                                  [s (hash-ref sessions sess-id)])
                                             (begin
                                               (if (qm-pair? s)
                                                   (if (eq? (qm-pair-alice s) conn) ; paired session
                                                       (ws-send! (qm-pair-bob s) msg)
                                                       (ws-send! (qm-pair-alice s) msg))
                                                       (ws-send! conn "session-not-paired")) ; unpaired session
                                                   state))]
          [else (ws-send! conn "no-session")])))

(define (handle-timer-tick-event state ev)
  state)

  
(define (main)
  (define ws-service (websocket-service event-bus port))
  (let loop ([as (app-state (hash)(hasheq))])
    (let ([rec-event (channel-get event-bus)])
      (loop (app-dispatcher as rec-event)))))
      