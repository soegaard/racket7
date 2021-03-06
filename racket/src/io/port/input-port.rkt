#lang racket/base
(require "../common/check.rkt"
         "../host/thread.rkt"
         "port.rkt"
         "evt.rkt")

(provide prop:input-port
         input-port?
         ->core-input-port
         (struct-out core-input-port)
         make-core-input-port)

(define-values (prop:input-port input-port-via-property? input-port-ref)
  (make-struct-type-property 'input-port
                             (lambda (v sti)
                               (check 'prop:input-port (lambda (v) (or (exact-nonnegative-integer? v)
                                                                       (input-port? v)))
                                      #:contract "(or/c input-port? exact-nonnegative-integer?)"
                                      v)
                               (check-immutable-field 'prop:input-port v sti)
                               (if (exact-nonnegative-integer? v)
                                   (make-struct-field-accessor (list-ref sti 3) v)
                                   v))
                             (list (cons prop:secondary-evt
                                         (lambda (v) port->evt))
                                   (cons prop:input-port-evt
                                         (lambda (i)
                                           (input-port-evt-ref (->core-input-port i)))))))

(define (input-port? p)
  (or (core-input-port? p)
      (input-port-via-property? p)))

;; This function should not be called in atomic mode,
;; since it can invoke an artitrary function
(define (->core-input-port v)
  (cond
    [(core-input-port? v) v]
    [(input-port? v)
     (let ([p (input-port-ref v)])
       (cond
         [(struct-accessor-procedure? p)
          (->core-input-port (p v))]
         [else
          (->core-input-port p)]))]
    [else
     empty-input-port]))

(struct core-input-port core-port
  (
   ;; Various functions below are called in atomic mode. The
   ;; intent of atomic mode is to ensure that the completion and
   ;; return of the function is atomic with respect to some further
   ;; activity, such as position and line counting. Any of the
   ;; functions is free to exit and re-enter atomic mode. Leave
   ;; atomic mode explicitly before raising an exception.

   read-byte ; #f or (-> (or/c byte? eof-object? evt?))
   ;;          Called in atomic mode.
   ;;          This shortcut is optional.
   ;;          Non-blocking byte read, where an event must be
   ;;          returned if no byte is available. The event's result
   ;;          is ignored, so it should not consume a byte.

   read-in   ; port or (bytes start-k end-k copy? -> (or/c integer? ...))
   ;;          Called in atomic mode.
   ;;          A port value redirects to the port. Otherwise, the function
   ;;          never blocks, and can assume `(- end-k start-k)` is non-zero.
   ;;          The `copy?` flag indicates that the given byte string should
   ;;          not be exposed to untrusted code, and instead of should be
   ;;          copied if necessary. The return values are the same as
   ;;          documented for `make-input-port`, except that a pipe result
   ;;          is not allowed (or, more precisely, it's treated as an event).

   peek-byte ; #f or (-> (or/c byte? eof-object? evt?))
   ;;          Called in atomic mode.
   ;;          This shortcut is optional.
   ;;          Non-blocking byte read, where an event must be
   ;;          returned if no byte is available. The event's result
   ;;          is ignored.

   peek-in   ; port or (bytes start-k end-k skip-k progress-evt copy? -> (or/c integer? ...))
   ;;          Called in atomic mode.
   ;;          A port value redirects to the port. Otherwise, the function
   ;;          never blocks, and it can assume that `(- end-k start-k)` is non-zero.
   ;;          The `copy?` flag is the same as for `read-in`.  The return values
   ;;          are the same as documented for `make-input-port`.

   byte-ready  ; port or (-> (or/c boolean? evt))
   ;;          Called in atomic mode.
   ;;          A port value makes sense when `peek-in` has a port value.
   ;;          Otherwise, check whether a peek on one byte would succeed
   ;;          without blocking and return a boolean, or return an event
   ;;          that effectively does the same. The event's value doesn't
   ;;          matter, because it will be wrapped to return some original
   ;;          port.

   get-progress-evt ; #f or (-> evt?)
   ;;           *Not* called in atomic mode.
   ;;           Optional support for progress events.

   commit    ; (amt-k progress-evt? evt?) -> (or/c bytes? #f)
   ;;          Called in atomic mode.
   ;;          Goes with `get-progress-evt`. The final `evt?`
   ;;          argument is constrained to a few kinds of events;
   ;;          see docs for `port-commit-peeked` for more information.
   ;;          The result is the committed bytes on success, #f on
   ;;          failure.

   [pending-eof? #:mutable]
   [read-handler #:mutable])
  #:authentic
  #:property prop:input-port-evt (lambda (i)
                                   (cond
                                     [(closed-state-closed? (core-port-closed i))
                                      always-evt]
                                     [else
                                      (define byte-ready (core-input-port-byte-ready i))
                                      (cond
                                        [(input-port? byte-ready)
                                         byte-ready]
                                        [else
                                         (poller-evt
                                          (poller
                                           (lambda (self sched-info)
                                             (define v (byte-ready))
                                             (cond
                                               [(evt? v)
                                                (values #f v)]
                                               [(eq? v #t)
                                                (values (list #t) #f)]
                                               [else
                                                (values #f self)]))))])])))

(define (make-core-input-port #:name name
                              #:data [data #f]
                              #:read-byte [read-byte #f]
                              #:read-in read-in
                              #:peek-byte [peek-byte #f]
                              #:peek-in peek-in
                              #:byte-ready byte-ready
                              #:close close
                              #:get-progress-evt [get-progress-evt #f]
                              #:commit [commit #f]
                              #:get-location [get-location #f]
                              #:count-lines! [count-lines! #f]
                              #:init-offset [init-offset 0]
                              #:file-position [file-position #f]
                              #:buffer-mode [buffer-mode #f])
  (core-input-port name
                   data

                   close
                   count-lines!
                   get-location
                   file-position
                   buffer-mode
                   
                   (closed-state #f #f)
                   init-offset ; offset
                   #f   ; count?
                   #f   ; state
                   #f   ; cr-state
                   #f   ; line
                   #f   ; column
                   #f   ; position
                   
                   read-byte
                   read-in
                   peek-byte
                   peek-in
                   byte-ready
                   get-progress-evt
                   commit
                   #f   ; pending-eof?
                   #f)) ; read-handler

(define empty-input-port
  (make-core-input-port #:name 'empty
                        #:read-in (lambda (bstr start-k end-k copy?) eof)
                        #:peek-in (lambda (bstr start-k end-k skip-k copy?) eof)
                        #:byte-ready (lambda () #f)
                        #:close void))
