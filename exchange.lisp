;;;; exchange.lisp

(defpackage #:scalpl.exchange
  (:use #:cl #:chanl #:anaphora #:local-time #:scalpl.util #:scalpl.actor)
  (:export #:http-request
           #:exchange #:name #:assets #:markets #:parse-timestamp
           #:*exchanges* #:find-exchange #:fetch-exchange-data
           #:asset #:find-asset #:asset-quantity
           #:quantity #:scaled-quantity #:cons-aq #:cons-aq* #:aq+ #:aq-
           #:market #:decimals #:primary #:counter #:find-market
           #:scaled-price #:cons-mp #:cons-mp* #:scalp #:aq/ #:aq*
           #:offer #:bid #:ask #:placed #:taken #:given
           #:volume #:price #:placed #:oid #:consumed-asset
           #:gate #:gate-post #:gate-request #:output #:input #:cache
           #:trade #:cost #:direction #:txid
           #:trades-tracker #:trades #:trades-since #:vwap
           #:book-tracker #:bids #:asks #:get-book #:get-book-keys
           #:balance-tracker #:balances #:sync #:print-book #:asset-funds
           #:placed-offers #:account-balances #:market-fee
           #:execution #:fee #:net-cost #:net-volume #:fee-tracker
           #:execution-tracker #:execution-since #:bases #:bases-without
           #:post-offer #:cancel-offer #:supplicant #:lictor #:treasurer
           #:order-slots #:response #:supplicate))

(in-package #:scalpl.exchange)

;;; Networking... dump it here, later should probably split into net.lisp

(defun http-request (path &rest keys &aux (backoff 0))
  (loop (handler-case (return (apply #'drakma:http-request path
                                     :connection-timeout 30 keys))
          ((or simple-error drakma::drakma-simple-error
            usocket:deadline-timeout-error usocket:timeout-error
            usocket:timeout-error usocket:ns-host-not-found-error
            end-of-file chunga::input-chunking-unexpected-end-of-file
            cl+ssl::ssl-error usocket:connection-refused-error)
              (error) (describe error) (sleep (incf backoff backoff))))))

;;; TODO
;;; This file should lay out the interface that each exchange client needs to
;;; implement. Each exchange client should instantiate the exchange class and
;;; specialize methods on generic functions, which should be defined here.

;;; TODO
;;; Some method for implemented exchange APIs to "register" the exchange, so
;;; we don't have to mess with a different package per exchange.

;;;
;;; Exchanges
;;;

(defvar *exchanges* (make-hash-table))

(defun find-exchange (name &aux (str (format () "scalpl.~(~A~)" name)))
  (symbol-macrolet ((get (gethash name *exchanges*)))
    (or get (awhen (asdf:find-system str) (asdf:load-system it) get))))

(defclass exchange ()
  ((name    :initarg :name    :reader name)
   (assets  :initarg :assets  :reader assets)
   (markets :initarg :markets :reader markets)
   ;; FIXME: broken af
   (market-timestamp-sensitivity :initarg :sensitivity)))

(defmethod initialize-instance :after ((exchange exchange) &key)
  (with-slots (name) exchange
    (setf (gethash name *exchanges*) exchange)))

(defgeneric fetch-exchange-data (exchange)
  (:documentation "Fetch metadata about assets and markets on this exchange.
Since fetching this information requires network access, it's performed on a
need-to-use basis, rather than upon initial loading of the exchange API.")
  (:method :after (exchange)
    (with-slots (assets markets) exchange
      (dolist (thing (append assets markets))
        (setf (slot-value thing 'exchange) exchange)))))

(defmethod slot-unbound ((class t) (exchange exchange) slot)
  (if (member slot '(assets markets))
      (progn (fetch-exchange-data exchange)
             (slot-value exchange slot))
      (call-next-method)))

(defmethod print-object ((exchange exchange) stream)
  (print-unreadable-object (exchange stream :type nil :identity nil)
    (princ (name exchange) stream)))

;;; FIXME these are de facto exchange dispatch hacked onto timestamp wtf
(defgeneric parse-timestamp (exchange timestamp)
  (:method ((exchange exchange) (sec integer)) (unix-to-timestamp sec))
  (:method ((exchange exchange) (timestamp real))
    (multiple-value-bind (sec nsec) (floor timestamp)
      (unix-to-timestamp sec :nsec (round (* (expt 10 9) nsec)))))
  (:method ((exchange exchange) (timestamp string))
    ;; asdfjkshanueodaoseitcgaeosundantheoudvwe;ercgu
    (parse-timestamp exchange (parse-float timestamp :type 'double-float))))

;;;
;;; Unit Registry
;;;

;;; https://en.wikipedia.org/wiki/Scalar_(physics)#Physical_quantity

(defvar *unit-registry* '(()))

(defclass registered-unit ()
  ((index :initform (length *unit-registry*) :reader index)))

(defmethod initialize-instance :after ((unit registered-unit) &key)
  (push (cons (index unit) unit) *unit-registry*))

(defun find-unit (index) (cdr (assoc index *unit-registry*)))

(defun physical-quantity-p (thing)
  (and (complexp thing) (find-unit (imagpart thing))))

(deftype physical-quantity () '(satisfies physical-quantity-p))

(defvar *pqprint-dispatch* (copy-pprint-dispatch))

(defun pprint-pq (stream pq)
  (with-slots (decimals name) (find-unit (imagpart pq))
    (format stream "~V$ ~A" decimals
            (/ (realpart pq) (expt 10 decimals) 1d0) name)))

(set-pprint-dispatch 'physical-quantity #'pprint-pq 1 *pqprint-dispatch*)

;;;
;;; Assets
;;;

(defclass asset (registered-unit)
  ((name     :initarg :name     :reader name)
   (decimals :initarg :decimals :reader decimals)
   (exchange :initarg :exchange :reader exchange)))

(defmethod print-object ((asset asset) stream)
  (print-unreadable-object (asset stream :type nil :identity nil)
    (format stream "~A on ~A" (name asset) (exchange asset))))

(defgeneric find-asset (designator exchange)
  (:method (designator (assets list))
    (find designator assets :key 'name :test 'string-equal))
  (:method (designator (exchange exchange))
    (find-asset designator (assets exchange)))
  (:method (designator (name symbol))
    (find-asset designator (find-exchange name))))

;;;
;;; Asset Quantities
;;;

(deftype asset-quantity ()
  "A precise quantity of a given asset"
  '(complex unsigned-byte))

(defun asset (aq) (cdr (assoc (imagpart aq) *unit-registry*)))
(defun quantity (aq) (realpart aq))
(defun scaled-quantity (aq) (/ (realpart aq) (expt 10 (decimals (asset aq)))))
(defun cons-aq (asset quantity) (complex (round quantity) (index asset)))
(defun cons-aq* (asset quantity)
  (cons-aq asset (* quantity (expt 10 (decimals asset)))))

(defun aq+ (aq1 aq2 &rest aqs)
  (assert (eq (asset aq1) (asset aq2)))
  (if aqs (reduce #'aq+ aqs :initial-value (aq+ aq1 aq2))
      (cons-aq (asset aq1) (+ (quantity aq1) (quantity aq2)))))

(defun aq- (aq1 &optional aq2 &rest aqs)
  (cond (aqs (aq- aq1 (reduce #'aq+ aqs :initial-value aq2)))
        (aq2 (assert (eq (asset aq1) (asset aq2)))
             (cons-aq (asset aq1) (- (quantity aq1) (quantity aq2))))
        (t   (cons-aq (asset aq1) (- (quantity aq1))))))

;;;
;;; Markets
;;;

(defclass market (registered-unit)
  ((name     :initarg :name     :reader name)
   (decimals :initarg :decimals :reader decimals)
   (exchange :initarg :exchange :reader exchange)
   (counter  :initarg :counter  :reader counter)
   (primary  :initarg :primary  :reader primary)))

(defmethod print-object ((market market) stream)
  (print-unreadable-object (market stream :type nil :identity nil)
    (format stream "~A on ~A" (name market) (exchange market))))

(defgeneric find-market (designator exchange)
  (:method (designator (markets list))
    (find designator markets :key 'name :test 'string-equal))
  (:method (designator (exchange exchange))
    (with-slots (markets) exchange
      (find-market designator markets)))
  (:method (designator (name symbol))
    (find-market designator (find-exchange name))))

;;;
;;; Market Prices
;;;

(deftype market-price ()
  "A precise price in a given market"
  '(complex unsigned-byte))

(defgeneric market (object)
  (:method (object) (slot-value object 'market))
  (:method ((mp complex)) (cdr (assoc (imagpart mp) *unit-registry*))))
(defmethod price (mp) (abs (realpart mp)))
(defun scaled-price (mp) (/ (price mp) (expt 10 (decimals (market mp)))))
(defun cons-mp (market price) (complex (round price) (index market)))
(defun cons-mp* (market price)
  (cons-mp market (* price (expt 10 (decimals market)))))
(defmethod direction ((mp complex)) (if (plusp (realpart mp)) 'ask 'bid))
(defun scalp (mp) (1- mp))              ; this is actually good news!

(defun aq/ (given taken &aux (ag (asset given)) (at (asset taken)))
  (assert (eq (exchange ag) (exchange at)) nil "assets from two exchanges")
  (dolist (market (markets (exchange ag))
           (error "no market between ~A and ~A" (name ag) (name at)))
    (flet ((build (sign numerator denominator)
             (return (cons-mp* market (/ (scaled-quantity numerator) sign
                                         (scaled-quantity denominator))))))
      (with-slots (primary counter) market
        (when (and (eq ag primary) (eq at counter)) (build +1 taken given))
        (when (and (eq ag counter) (eq at primary)) (build -1 given taken))))))

(defun aq* (mp aq &aux (q (scaled-quantity aq)) (p (scaled-price mp)))
  (with-slots (primary counter) (market mp)
    (cond ((eq (asset aq) primary) (cons-aq* counter (* q p)))
          ((eq (asset aq) counter) (cons-aq* primary (/ q p)))
          (t (error "~A not traded in ~A" (asset aq) (market mp))))))

;;;
;;; Offers
;;;

(defclass offer ()
  ((market :initarg :market :reader market)
   (taken  :initarg :taken  :reader taken)
   (given  :initarg :given  :reader given)
   (volume :initarg :volume :accessor volume)
   (price  :initarg :price  :reader price)))

(defclass placed (offer)
  ((oid    :initarg :oid    :reader oid)))

(defclass bid (offer) ()) (defclass ask (offer) ())

(defun consumed-asset (offer) (asset (given offer)))

(defmethod initialize-instance ((bid bid) &rest keys &key price)
  (apply #'call-next-method bid :price (- (abs price)) keys))

(defmethod shared-initialize :after ((offer offer) (names t) &key)
  (with-slots (market taken given volume price) offer
    (macrolet ((do-slot (slot aside primary bside counter)
                 `(unless (slot-boundp offer ',slot)
                    (setf ,slot (if (plusp price)
                                    (cons-aq* (,aside market) ,primary)
                                    (cons-aq* (,bside market) ,counter))))))
      (let ((factor (/ (abs price) (expt 10 (decimals market)))))
        (do-slot given primary volume counter (* volume factor))
        (do-slot taken counter (* volume factor) primary volume)))))

(defmethod print-object ((offer offer) stream)
  (print-unreadable-object
        (offer stream :type (not (typep offer 'placed)))
    (with-slots (given price market) offer
      (let ((market-decimals (slot-value market 'decimals)))
        (format stream "~@[~A ~]~A @ ~V$" (ignore-errors (oid offer)) given
                market-decimals (/ (abs price) (expt 10 market-decimals)))))))

;;;
;;; Rate Gate
;;;

(defclass gate (actor)
  ((exchange :initarg :exchange :initform (error "EI4NI"))
   (pubkey :initarg :pubkey :initform (error "gate requires API pubkey"))
   (secret :initarg :secret :initform (error "gate requires API secret"))
   (input  :initarg :input  :initform (make-instance 'channel))
   (output :initarg :output :initform (make-instance 'channel))
   (cache  :initform nil)))

(defmethod christen ((gate gate) (type (eql 'actor)))
  (subseq (slot-value gate 'pubkey) 0 3))

(defgeneric gate-post (gate pubkey secret request)
  (:documentation "Attempts to perform `request' with the provided credentials.")
  (:method :around (gate pubkey secret request)
    (rplacd request                     ; restart may belong in actors.lisp
            (restart-case (call-next-method gate pubkey secret (cdr request))
              (abort () :report "Abort request, keep gate" '(() :aborted))))))

(defmethod perform ((gate gate) &key)
  (call-next-method gate :blockp ())
  (with-slots (input output . #1=(exchange pubkey secret cache)) gate ;¡ has-a !
    (when (send-blocks-p output) (setf cache (recv input)))
    (send (slot-value gate 'output) (gate-post . #1#))))

(defmethod halt :before ((gate gate))
  (pexec (:name "gate kill helper")
    (loop until (account-balances gate) do (sleep 15))))

(defun gate-request (gate path &optional options &aux (id (cons path options)))
  (with-slots (input output) gate
    (send input (list* id path options))
    (loop for reply = (recv output) until (eq (car reply) id)
       do (send output reply) finally (return (values-list (cdr reply))))))

;;;
;;; Public Data API
;;;

(defgeneric trades-since (market &optional since))
(defgeneric get-book (market &key))

;;; should trade direction be represented as:
;;; a boolean slot?
;;; slots for (consumed|earned)×(volume|asset)?
;;; distinct buy and sell mixin classes/objects?

(defclass trade ()
  ((market    :initarg :market    :reader market)
   (volume    :initarg :volume    :reader volume)
   (price     :initarg :price     :reader price) ; aq?
   (cost      :initarg :cost      :reader cost)
   (taken     :initarg :taken     :reader taken)
   (given     :initarg :given     :reader given)
   (txid      :initarg :txid      :reader txid)
   (timestamp :initarg :timestamp :reader timestamp)
   (direction :initarg :direction :reader direction)))

(defmethod shared-initialize :after ((trade trade) names &key)
  (with-slots (market taken given volume price direction) trade
    ((lambda (primary counter)
       (let ((butterfingerp (char-equal (char direction 0) #\s)))
         (when (or (eq names t) (find 'given names))
           (setf given (if butterfingerp primary counter)))
         (when (or (eq names t) (find 'taken names))
           (setf taken (if butterfingerp counter primary)))))
     (cons-aq* (primary market) volume)
     (with-slots (counter decimals) market
       (cons-aq* counter (* volume (/ (abs price) (expt 10 decimals))))))))

(defmethod print-object ((trade trade) stream)
  (print-unreadable-object (trade stream :identity nil)
    (with-slots (market volume price timestamp direction) trade
      (with-slots (primary decimals) market
        (format stream "~A ~A at ~V$: ~V$" timestamp
                direction decimals price (decimals primary) volume)))))

(defclass trades-fetcher (actor) ())

(defmethod christen ((fetcher trades-fetcher) (type (eql 'actor)))
  (format nil "trade fetcher ~A" (market fetcher)))

(defmethod perform ((fetcher trades-fetcher) &key)
  (with-slots (market buffer delay)
      (first (slot-value fetcher 'delegates)) ; FIXME MUCH BAD SUCH HATE
    (dolist (trade (trades-since market (recv buffer))) (send buffer trade))
    (sleep delay)))

(defclass trades-tracker (parent)
  ((market :initarg :market :reader market)
   (delay  :initarg :delay  :initform 47)
   (buffer :initform (make-instance 'channel))
   (output :initform (make-instance 'channel))
   (trades :initform nil) fetcher))

(defmethod christen ((tracker trades-tracker) (type (eql 'actor)))
  (format nil "trade tracker ~A" (market tracker)))

(defmethod perform ((tracker trades-tracker) &key)
  (with-slots (buffer trades market output) tracker
    (let ((last (car trades)))
      (select
        ((send buffer last)) ((send output trades)) ;D   ^V^   ]:C
        ((recv buffer next)             ;              batsign
         (if (trades-mergeable? tracker last next)
             (setf (car trades) (merge-trades tracker last next))
             (push next trades)))
        (t (sleep 0.2))))))

(defmethod initialize-instance :after ((tracker trades-tracker) &key)
  (adopt tracker (setf (slot-value tracker 'fetcher)
                       (make-instance 'trades-fetcher :delegates `(,tracker)))))

(defgeneric vwap (tracker &key &allow-other-keys)
  (:method :around ((tracker t) &key)
    (handler-case (call-next-method) (division-by-zero () 0)))
  (:method ((tracker trades-tracker) &key since depth type)
    (let ((trades (slot-value tracker 'trades)))
      (when since (setf trades (remove since trades
                                       :key #'timestamp :test #'timestamp>=)))
      (when type
        (setf trades (remove (ccase type (:buy #\b) (:sell #\s)) trades
                             :key (lambda (trade) (char (direction trade) 0))
                             :test-not #'char-equal)))
      (when depth
        (setf trades (loop for trade in trades collect trade
                           sum (volume trade) into sum
                           until (>= sum depth))))
      (/ (reduce #'+ (mapcar #'cost trades))
         (reduce #'+ (mapcar #'volume trades))))))

;;; look at us, thinking of the future already
;;; we also dispatch on trades-tracker so that exchange-specific methods can
;;; dispatch on just the tracker argument, rather than both prev and next
;;; face it, sometimes you just gotta (eval '(expt +evil+ 1/2))

(defgeneric trades-mergeable? (trades-tracker prev next)
  (:method-combination and)
  (:method and ((tracker t) (prev null) (next t)))
  (:method and ((tracker trades-tracker) (prev trade) (next trade))
    (with-slots (exchange) (slot-reduce tracker market)
      (when (slot-boundp exchange 'market-timestamp-sensitivity)
        (with-slots (market-timestamp-sensitivity) exchange
          (and (string= (direction prev) (direction next))
               (> market-timestamp-sensitivity
                  (timestamp-difference (timestamp next) (timestamp prev)))))))))

;; (defgeneric same-trades? (trades-tracker prev next)
;;   (:method-combination and)
;;   (:method and ()))

(defgeneric merge-trades (trades-tracker prev next)
  (:method ((tracker trades-tracker) (prev trade) (next trade))
    (let* ((volume (+ (volume prev) (volume next)))
           (cost   (+ (cost   prev) (cost   next)))
           (price (/ cost volume)))
      (make-instance 'trade :market (market prev)
                     :txid (ignore-errors (txid next)) ;hack
                     :timestamp (timestamp next) :cost cost
                     :volume volume :price price
                     :direction (direction prev)))))

(defmethod timestamp ((object null)))   ; such lazy

;;;
;;; ORDER BOOK
;;;

(defclass book-fetcher (actor) ())

(defmethod christen ((fetcher book-fetcher) (type (eql 'actor)))
  (format nil "depth fetcher ~A" (market fetcher)))

(defmethod perform ((fetcher book-fetcher) &key)
  (with-slots (buffer delay market get-book-keys) fetcher
    (send buffer (multiple-value-call 'cons
                   (apply #'get-book market get-book-keys)))
    (sleep delay)))

(defclass book-tracker (parent)
  ((market :initarg :market :reader market :initform (error "required"))
   (get-book-keys :initform nil :initarg :get-book-keys)
   (delay :initarg :delay :initform 41) (book :initform ())
   (buffer :initform (make-instance 'channel)) fetcher
   (output :initform (make-instance 'channel))))

(defmethod christen ((tracker book-tracker) (type (eql 'actor)))
  (format nil "depth tracker ~A" (market tracker)))

(defmethod perform ((tracker book-tracker) &key)
  (with-slots (buffer book output) tracker
    (select ((recv buffer next) (setf book (cons (cdr next) (car next))))
            ((send output book)) (t (sleep 0.2)))))

(defmethod initialize-instance :after ((tracker book-tracker) &key)
  (adopt tracker (setf (slot-value tracker 'fetcher)
                       (make-instance 'book-fetcher :delegates `(,tracker)))))

;;;
;;; Putting things together
;;;

(defclass tracked-market (market parent)
  ((%market :initarg :market) (book :reader book) (trades :reader trades)
   book-tracker trades-tracker))        ; unleash the cspaken!

;;; shameful? ☑ disgusting? ☑ preserves dispatch? ☑
(defmethod update-instance-for-different-class :after
    ((prev market) (new tracked-market) &key)
  (macrolet ((init (feed &aux (class (intern (format nil "~A-TRACKER" feed))))
               `(adopt new (aprog1 (make-instance ',class :market %market)
                             (setf (slot-value new ',class) it
                                   (slot-value new ',feed)
                                   (slot-value it 'output))))))
    (with-slots (%market book trades) new
      (setf %market (shallow-copy prev)) (init book) (init trades))))

;;; tonight we dine in fail
(defmethod get-book ((market tracked-market) &key)
  (get-book (slot-value market '%market)))

(defmethod vwap ((market tracked-market) &rest keys)
  (apply #'vwap (slot-value market 'trades-tracker) keys))

(defmethod ensure-running ((market market))
  (change-class market 'tracked-market))
(defmethod ensure-running ((market tracked-market)) market)

(defgeneric print-book (book &key &allow-other-keys)
  (:method ((book cons) &key count prefix ours)
    (destructuring-bind (bids . asks) book
      (flet ((width (side)
               (flet ((vol (o) (quantity (given o))))
                 (loop for o in side repeat (or count 15)
                    for max = o then (if (> (vol o) (vol max)) o max)
                    finally (return (length (princ-to-string max)))))))
        (let ((ctrl (multiple-value-call #'format
                      () "~~&~~@[~~A ~~]~~~D@A ~~~D@A~~%"
                      (if (atom ours) (values (width bids) (width asks))
                          (destructuring-bind (my-bids . my-asks) ours
                            (values (max (width bids) (width my-bids))
                                    (max (width asks) (width my-asks))))))))
          (flet ((line (bid ask) (format t ctrl prefix bid ask)))
            (if (atom ours)
                (do ((bids bids (rest bids)) (asks asks (rest asks)))
                    ((or (and (null bids) (null asks))
                         (and (numberp count) (= -1 (decf count)))))
                  (line (first bids) (first asks)))
                (macrolet ((side (stash mine book)
                             `(and ,mine (>= (price (car ,book))
                                             (price (car ,mine)))
                                   (> (volume (car ,book))
                                      (volume (setf ,stash (pop ,mine)))))))
                  (do ((my-bids (car ours)) (my-asks (cdr ours))
                       (bids bids) (asks asks) (mbid () ()) (mask () ()))
                      ((or (and (null bids) (null asks))
                           (and (numberp count) (= -1 (decf count)))))
                    (let ((bs (side mbid my-bids bids))
                          (as (side mask my-asks asks)))
                      (line (or mbid (car bids)) (or mask (car asks)))
                      (or bs (pop bids)) (or as (pop asks))))))
            (flet ((shit (shinola)      ; so es dreht...
                     (when shinola (reduce #'aq+ (mapcar #'given shinola)))))
              (format t "~&Totals:~%") (line (shit bids) (shit asks))))))))
  (:method ((tracker book-tracker) &rest keys)
    (apply #'print-book (recv (slot-value tracker 'output)) keys))
  (:method ((market tracked-market) &rest keys)
    (apply #'print-book (slot-value market 'book-tracker) keys)))

;;;
;;; Private Data API
;;;

(defgeneric placed-offers (gate))
(defgeneric account-balances (gate))

(defclass balance-tracker (actor)
  ((fuzz :initarg :fuzz :initform (random 7))
   (sync :initarg :sync :initform (make-instance 'channel))
   (balances :initarg :balances :initform ())
   (reserved :initarg :reserved :initform ())
   (abbrev :allocation :class :initform "funds")))

(defmethod perform ((tracker balance-tracker) &key)
  (with-slots (gate sync fuzz balances reserved) tracker
    (let ((target (recv sync)))         ; back and forth
      (when (zerop (random fuzz))       ; in the absence of memory...
        (awhen1 (account-balances gate) ; maybify API failability
          (setf balances                ; sub-clude the reserved aqs
                (loop for aq in it for asset = (asset aq) collect
                     (aif (remove asset reserved ;key #'cxbtc
                                  :test-not #'eq :key #'asset)
                          (aq- aq (reduce  ;_; should (zerop (aq+))?
                                   #'aq+ it ; like maybe patterns!?
                                   :initial-value (cons-aq asset 0)))
                          aq)))))
      (send target balances))))

(defmethod christen ((tracker balance-tracker) (type (eql 'actor)))
  (slot-reduce tracker gate name))

(defun asset-funds (asset funds)
  (aif (find asset funds :key #'asset) (scaled-quantity it) 0))

(defgeneric market-fee (gate market)
  (:documentation "(bid . ask) fees, in percent")
  (:method :around ((gate gate) (market market))
    (actypecase (call-next-method) (number `(,it . ,it)) (cons it) (null))))

(defclass fee-fetcher (actor)
  ((abbrev :allocation :class :initform "fee fetcher")))

(defmethod christen ((fetcher fee-fetcher) (type (eql 'actor)))
  (with-slots (gate market) fetcher
    (format nil "~A ~A" (name gate) (name market))))

(defclass fee-tracker (parent)
  ((abbrev :allocation :class :initform "fee tracker")
   (delay  :initarg :delay  :initform 127) fee fetcher
   (input  :initarg :input  :initform (make-instance 'channel))
   (output :initarg :output :initform (make-instance 'channel))))

(defmethod christen ((tracker fee-tracker) (type (eql 'actor)))
  (with-slots (gate market) tracker
    (format nil "~A ~A" (name gate) (name market))))

(defmethod perform ((fetcher fee-fetcher) &key)
  (with-slots (market gate delay input) fetcher
    (awhen (market-fee gate market) (send input it))
    (sleep delay)))

(defmethod perform ((tracker fee-tracker) &key)
  (with-slots (input output fee) tracker
    (ignore-errors (select ((recv input new) (setf fee new))
                           ((send output fee)) (t (sleep 1/7))))))

(defmethod initialize-instance :after ((tracker fee-tracker) &key)
  (adopt tracker (setf (slot-value tracker 'fetcher)
                       (make-instance 'fee-fetcher :delegates (list tracker)))))

;;;
;;; EXECUTION TRACKING
;;;

(defclass execution (trade)
  ((oid :initarg :oid :reader oid)
   (fee :initarg :fee :reader fee)
   (net-cost :initarg :net-cost :reader net-cost)
   (net-volume :initarg :net-volume :reader net-volume)))

(defmethod shared-initialize :after ((execution execution) names &key)
  (with-slots (market taken given net-volume net-cost direction) execution
    ((lambda (primary counter)
       (let ((butterfingerp (char-equal (char direction 0) #\s)))
         (when (or (eq names t) (find 'given names))
           (setf given (if butterfingerp primary counter)))
         (when (or (eq names t) (find 'taken names))
           (setf taken (if butterfingerp counter primary)))))
     (cons-aq* (primary market) net-volume)
     (cons-aq* (counter market) net-cost))))

(defclass execution-fetcher (actor)
  ((abbrev :allocation :class :initform "exhun fetcher")))

(defmethod christen ((fetcher execution-fetcher) (type (eql 'actor)))
  (with-slots (gate market) fetcher
    (format nil "~A ~A" (name gate) (name market))))

(defmethod perform ((fetcher execution-fetcher) &key)
  (with-slots (gate market buffer delay) fetcher
    (dolist (trade (execution-since gate market (recv buffer)) (sleep delay))
      (send buffer trade))))

(defclass execution-tracker (parent)
  ((abbrev :allocation :class :initform "exhun tracker")
   (trades :initform nil) (bases :initform nil)
   (delay :initform 59) (buffer :initform (make-instance 'channel)) fetcher))

(defmethod christen ((tracker execution-tracker) (type (eql 'actor)))
  (with-slots (gate market) tracker
    (format nil "~A ~A" (name gate) (name market))))

(defmethod execute ((tracker execution-tracker) (command (eql :rebase)))
  (with-slots (bases trades) tracker
    (setf bases nil) (dolist (next (reverse trades))
                       (update-bases tracker next))))

(defmethod perform ((tracker execution-tracker) &key)
  (with-slots (buffer trades bases control) tracker
    (select ((recv buffer next)
             (update-bases tracker next) (push next trades))
            ((recv control command) (execute tracker command))
            ((send buffer (first trades))) (t (sleep 0.2)))))

(defmethod initialize-instance :after ((tracker execution-tracker) &key)
  (adopt tracker
         (setf (slot-value tracker 'fetcher)
               (make-instance 'execution-fetcher :delegates `(,tracker)))))

(defgeneric execution-since (gate market since))

;;; This function returns three values:
;;;   1) remaining bases, after deducting the given aq (can be nil)
;;;   2) the vwab price of the given bases
;;;   3) the actual cost of the given bases
;;; What is it fed?
;;;   bases - just the ones for the asset-to-give, from the relevant market
;;;   aq - that you wish to give
;;; Who calls it?
;;;   update-bases, to compute the remaining basis for a given asset
;;;   ope-spreader (TODO), to check whether a certain offer is profitable

(defun bases-without (bases given)
  (handler-case
      (loop for basis = (pop bases) for (bp baq other) = basis
         for acc = baq then (aq+ acc baq) for vwab-sum = other
         then (aq+ vwab-sum other) sum (* (price bp) (quantity baq)) into pwa
         when (> (quantity acc) (quantity given)) return
           (let* ((excess (aq- acc given))
                  (other (cons-aq (asset other)
                                  (* (quantity other)
                                     (/ (quantity excess) (quantity baq)))))
                  (recur (aq- vwab-sum other)))
             (values (cons (list bp excess other) bases)
                     (cons-mp (market bp)
                              (/ (- pwa (* (price bp) (quantity excess)))
                                 (quantity given))) recur))
         when (null bases) return
           (values nil (aq/ vwab-sum acc) vwab-sum))
    ((or division-by-zero arithmetic-error) ())))

(defun update-bases (tracker trade)
  (with-slots (bases) tracker
    (with-slots (taken given price market) trade
      (swhen (getf bases (asset given)) (setf it (bases-without it given)))
      (setf (getf bases (asset taken))
            (merge 'list (copy-list (getf bases (asset taken)))
                   (list (list (aq/ given taken) taken given))
                   #'> :key (lambda (row) (realpart (first row))))))))

(defmethod vwap ((tracker execution-tracker) &key type depth)
  (let ((trades (slot-value tracker 'trades)))
    (when type
      (setf trades (remove type trades :key #'direction :test #'string-not-equal)))
    (when depth (setf trades
                      (loop for trade in trades collect trade
                         sum (volume trade) into sum until (>= sum depth))))
    (/ (reduce '+ (mapcar #'net-cost trades))
       (reduce '+ (mapcar #'net-volume trades)))))

(defmethod print-book ((lictor execution-tracker) &rest keys)
  (with-slots (bases market) lictor
    (flet ((basis-offer (basis)
             (make-instance 'offer :price (first basis) :market market
                            :taken (second basis) :given (third basis))))
      (with-slots (primary counter) market
        (apply #'print-book
               (cons (mapcar #'basis-offer (getf bases counter))
                     (mapcar #'basis-offer (getf bases primary)))
               keys)))))

;;;
;;; Action API
;;;

(defgeneric post-offer (gate offer))
(defgeneric cancel-offer (gate offer)
  (:method ((gate gate) (offer offer))
    (warn "Tried cancelling unplaced offer ~A" offer)))

(defclass supplicant (parent)
  ((gate :initarg :gate) (market :initarg :market :reader market) placed
   (response :initform (make-instance 'channel))
   (abbrev :allocation :class :initform "supplicant")
   (treasurer :initarg :treasurer) (lictor :initarg :lictor) (fee :initarg :fee)
   (order-slots :initform 40 :initarg :order-slots)))

(defun offers-spending (ope asset)
  (remove asset (slot-value ope 'placed)
          :key #'consumed-asset :test-not #'eq))

(defun balance-guarded-place (ope offer &aux (asset (consumed-asset offer)))
  (with-slots (gate placed order-slots treasurer) ope
    (let* ((spending (offers-spending ope asset))
           (mapreduc (reduce #'aq+ (mapcar #'given spending)
                             :initial-value (given offer)))
           (ourfunds (asset-funds asset (slot-reduce treasurer balances))))
      (when (and (>= ourfunds (scaled-quantity mapreduc))
                 (> order-slots (length placed)))
        (awhen1 (post-offer gate offer) (push it placed))))))

(defgeneric supplicate (supplicant gate op args)
  (:method ((supplicant supplicant) (gate gate) (op (eql :cancel)) id)
    (awhen1 (cancel-offer gate id)
      (with-slots (placed) supplicant
        (setf placed (remove (oid id) placed :key #'oid)))))
  (:method ((supplicant supplicant) (gate gate) (op (eql :offer)) args)
    (balance-guarded-place supplicant args)))

(defmethod execute ((supplicant supplicant) (command cons))
  (with-slots (gate response) supplicant
    (send response (supplicate supplicant gate (car command) (cdr command)))))

(defmethod christen ((supplicant supplicant) (type (eql 'actor)))
  (with-aslots (gate market) supplicant
    (format nil "~A ~A" (name gate) (name market))))

(defmethod initialize-instance :after ((supp supplicant) &key)
  (macrolet ((init (slot class)
               `(unless (ignore-errors ,slot)
                  (adopt supp (setf ,slot (make-instance
                                           ',class :delegates `(,supp)))))))
    (with-slots (fee lictor treasurer placed market gate) supp
      (adopt supp (ensure-running market)) (adopt supp gate)
      (init   fee          fee-tracker)
      (init  lictor  execution-tracker)
      (init treasurer  balance-tracker)
      (unless (ignore-errors placed)
        (setf placed (placed-offers gate))))))
