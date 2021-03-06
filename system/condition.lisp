;;;; Copyright (c) 2011-2015 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

;;; The condition/error system.

(in-package :sys.int)

(defparameter *break-on-signals* nil)
(defparameter *active-handlers* nil)

(defmacro define-condition (name (&rest parent-types) (&rest slot-specs) &rest options)
  (let ((report (assoc :report options)))
    `(progn
      (defclass ,name ,(or parent-types
			    '(condition))
	 ,slot-specs
	 ,@(remove :report options :key 'car))
      ,@(when report
	      (list `(defmethod print-object ((condition ,name) stream)
		       (if *print-escape*
			   (call-next-method)
			   (funcall #',(if (stringp (second report))
					   `(lambda (condition stream)
					      (declare (ignore condition))
					      (write-string ,(second report) stream))
					   (second report))
				    condition stream)))))
      ',name)))

(define-condition condition (standard-object)
  ()
  (:report (lambda (condition stream)
	     (format stream "The condition ~S was signalled." (class-name (class-of condition))))))

(define-condition serious-condition (condition)
  ())

(define-condition simple-condition (condition)
  ((format-control :initarg :format-control
		   :initform nil
		   :reader simple-condition-format-control)
   (format-arguments :initarg :format-arguments
		     :initform nil
		     :reader simple-condition-format-arguments))
  (:report (lambda (condition stream)
	     (if (simple-condition-format-control condition)
		 (apply #'format stream
			(simple-condition-format-control condition)
			(simple-condition-format-arguments condition))
		 (call-next-method)))))

(defun make-condition (type &rest slot-initializations)
  (declare (dynamic-extent slot-initializations))
  (apply #'make-instance type slot-initializations))

(defun coerce-to-condition (default datum arguments)
  (cond ((symbolp datum)
	 (apply #'make-condition datum arguments))
	((or (stringp datum)
	     (functionp datum))
	 (make-condition default
			 :format-control datum
			 :format-arguments arguments))
	((and (typep datum 'condition)
	      (null arguments))
	 datum)
	(t (error "Invalid condition designator ~S ~S." datum arguments))))

(defun signal (datum &rest arguments)
  (declare (dynamic-extent arguments))
  (let ((condition (coerce-to-condition 'simple-condition datum arguments)))
    (when (and *break-on-signals* (typep condition *break-on-signals*))
      (let ((*break-on-signals* nil))
	(break "Condition: ~S~%BREAK entered due to *BREAK-ON-SIGNALS*" condition)))
    (dolist (handlers *active-handlers*)
      (dolist (h handlers)
	(when (typep condition (car h))
	  (let ((*active-handlers* '()))
	    (funcall (cdr h) condition)))))
    nil))

(defmacro handler-bind (bindings &body forms)
  `(let ((*active-handlers* (cons (list ,@(mapcar (lambda (binding)
						    (destructuring-bind (type handler)
							binding
						      `(cons ',type ,handler)))
						  bindings))
				  *active-handlers*)))
     (declare (dynamic-extent *active-handlers*))
     (progn ,@forms)))

(eval-when (:compile-toplevel :load-toplevel :execute)
(defun compute-handler-case-forms (clauses)
  (let ((block-name (gensym))
	(condition-var (gensym))
	(handler-bind-forms '())
	(tagbody-forms '()))
    (dolist (clause clauses)
      (destructuring-bind (typespec (&optional var) &body body)
	  clause
	(let ((tag (gensym)))
	  (push `(,typespec #'(lambda (temp)
				(setq ,condition-var temp)
				(go ,tag)))
		handler-bind-forms)
	  (push `(return-from ,block-name ,(if var
					       `(let ((,var ,condition-var))
						  ,@body)
					       `(locally ,@body)))
		tagbody-forms)
	  (push tag tagbody-forms))))
    (values (nreverse handler-bind-forms) tagbody-forms block-name condition-var)))
)

(defmacro handler-case (expression &rest clauses)
  (let ((no-error (assoc :no-error clauses)))
    (if no-error
	;; Strip out :no-error clauses.
	(let ((error-return (make-symbol "error-return"))
	      (normal-return (make-symbol "normal-return")))
	  `(block ,error-return
	     (multiple-value-call #'(lambda ,(second no-error) ,@(cddr no-error))
	       (block ,normal-return
		 (return-from ,error-return
		   (handler-case (return-from ,normal-return ,expression)
		     ,@(remove no-error clauses)))))))
	  (multiple-value-bind (handler-bind-forms tagbody-forms block-name condition-var)
	      (compute-handler-case-forms clauses)
	    `(block ,block-name
	       (let ((,condition-var nil))
		 (declare (ignorable ,condition-var))
		 (tagbody
		    (handler-bind ,handler-bind-forms
		      (return-from ,block-name ,expression))
		    ,@tagbody-forms)))))))

(defmacro ignore-errors (&body forms)
  `(handler-case (progn ,@forms)
     (error (condition) (values nil condition))))
