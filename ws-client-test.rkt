#lang racket/base

(require net/rfc6455
         net/url)

(define c (ws-connect (string->url "ws://localhost:8081/qbit")))

(let loop ()
  (sync (handle-evt c
                    (lambda (m)
                      (printf m)
                      (unless (eof-object? m)
                        (loop))))
        (handle-evt (current-input-port)
                    (lambda _
                      (let ([r (read-line)])
                        (unless (equal? r "")
                          (ws-send! c r)
                           (loop)))))))