;;; redis-extras.scm -- Provides a DB allocator and proxy objects
;;;   Copyright © 2012 by Matthew C. Gushee

(use redis-client)
(use srfi-69)

(module redis-extras
        ( init
          with-db-select
          make-hash-proxy
          hash-proxy->hash-table
          hash-table->hash-proxy )

        (import scheme)
        (import chicken)
        (import srfi-69)
        (import redis-client)


;;; ============================================================================
;;; --  GLOBAL PARAMETERS  -----------------------------------------------------

;; FIXME -- obviously this should not be hard-coded. Need to figure out how
;;   to query Redis for this info. (redis-config "get" "databases") doesn't
;;   appear to work.
(define *total-dbs* (make-parameter 16))

(define *default-host* (make-parameter "localhost"))

(define *default-port* (make-parameter 6379))

(define *connected* (make-parameter #f))

(define *current-app* (make-parameter #f))

;;; ============================================================================



;;; ============================================================================
;;; ----------------------------------------------------------------------------

(define (first-available-index indices)
  (let ((indices* (map string->number indices))
        (last-idx (- (*total-dbs*) 1)))
    (let loop ((i 1))
      (cond
        ((> i last-idx) #f)
        ((memv i indices*) (loop (+ i 1)))
        (else i)))))

(define (get-db-index app-id)
  (redis-select "0")
  (let ((exists (car (redis-exists app-id))))
    (and (= exists 1)
         (car (redis-hget app-id "db-index")))))

(define (allocate-db app-id)
  (redis-select "0")
  (let* ((allocated-dbs (redis-smembers "dbs-in-use"))
         (available-index (first-available-index allocated-dbs)))
    (if available-index
      (let ((index (number->string available-index)))
        (redis-multi)
        (redis-hset app-id "db-index" index)
        (redis-sadd "dbs-in-use" index)
        (redis-exec))
      (abort "No dbs available."))))

(define (deallocate-db app-id)
  (let ((index (get-db-index app-id)))
    (print "INDEX: " index)
    (redis-multi)
    (redis-select index)
    (redis-flushdb)
    (redis-select "0")
    (redis-hdel app-id "db-index")
    (redis-srem "dbs-in-use" index)
    (redis-exec)))

(define (with-db-select thunk)
  (let ((app (*current-app*)))
    (when (not app)
      (abort "Current app is not set."))
    (let ((idx (get-db-index app)))
      (redis-select idx)
      (thunk))))

(define (init #!optional app-id #!key (host (*default-host*)) (port (*default-port*)))
  (when (not (*connected*))
    (redis-connect host port)
    (*connected* #t))
  (redis-select "0")
  (let ((in-use-exists (redis-exists "dbs-in-use")))
    (when (= (car in-use-exists) 0)
      (redis-sadd "dbs-in-use" "0"))
    (when app-id
      (*current-app* app-id)
      (or (get-db-index app-id)
        (allocate-db app-id)))))

;;; ============================================================================



;;; ============================================================================
;;; --  PROXY OBJECTS  ---------------------------------------------------------

(define (make-hash-proxy tag)
  (lambda (cmd . args)
    (case cmd
      ((key)
       tag)
      ((get)
       (redis-hget tag (car args)))
      ((set!)
       (redis-hset tag (car args) (cadr args)))
      ((for-each)
       (let ((fields (redis-hkeys tag))
             (f (car args)))
         (for-each f fields))))))

(define (hash-table->hash-proxy key ht)
  (let ((hp (make-hash-proxy key)))
    (hash-table-for-each ht (lambda (k v) (hp 'set k v)))
    hp))

(define (hash-proxy->hash-table hp)
  (let ((key (hp 'key))
        (ht (make-hash-table)))
    (hp 'for-each
        (lambda (field)
          (let ((value (redis-hget key field)))
            (hash-table-set! ht field value))))
    '(key ht)))


;;; ============================================================================

)


;;; ============================================================================
;;; ----------------------------------------------------------------------------