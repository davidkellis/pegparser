# Based on https://github.com/ohmlang/sle17/blob/master/src/standard.js
# https://ohmlang.github.io/pubs/sle2017/incremental-packrat-parsing.pdf
# https://tratt.net/laurie/research/pubs/html/tratt__direct_left_recursive_parsing_expression_grammars/
# http://www.vpri.org/pdf/tr2007002_packrat.pdf

# Per http://bford.info/pub/lang/peg.pdf:
# Definition:
# A parsing expression grammar (PEG) is a 4-tuple G = (VN, VT, R, eS),
# where VN is a finite set of nonterminal symbols, 
# VT is a finite set of terminal symbols, 
# R is a finite set of rules, 
# eS is a parsing expression termed the start expression, and 
# VN intersection VT = empty set.
# Each rule r ∈ R is a pair (A,e), which we write A <- e, where
# A ∈ VN and e is a parsing expression. For any nonterminal A, there
# is exactly one e such that (A <- e) ∈ R. R is therefore a function
# from nonterminals to expressions, and we write R(A) to denote the
# unique expression e such that (A <- e) ∈ R.

require "./dsl"
require "./parse_tree"
require "./visitor"

module Arborist
  class MemoResult
    property parse_tree : ParseTree?    # the parse tree matched at the index position within the memotable array at which this memoresult exists
    property nextPos : Int32

    def initialize(@parse_tree = nil, @nextPos = 0)
    end
  end

  alias Column = Hash(String, MemoResult)

  class Rule
    getter matcher : Matcher
    property name : String
    property expr : Expr

    def initialize(@matcher, @name, @expr)
    end

    def to_s
      "#{@name} -> #{@expr.to_s}"
    end
  end

  # The various ExprCall classes represent invocations, or calls, of the various expression types, at different positions
  # in an input string. The invocations/calls form a call stack, because a PEG parser is by nature a recursive descent parser,
  # and each rule application and the evaluations of the different expressions that make up those rules form a call stack.
  class ExprCall
    property expr : Expr
    property pos : Int32

    def initialize(@expr, @pos)
    end

    def inspect(io)
      io.print("#{self.class.name}:#{self.object_id} at #{@pos}: #{@expr.class.name} #{@expr.to_s}")
    end
  end

  class TerminalCall < ExprCall
  end
  class ChoiceCall < ExprCall
  end
  class SequenceCall < ExprCall
  end
  class NegLookAheadCall < ExprCall
  end
  class PosLookAheadCall < ExprCall
  end
  class OptionalCall < ExprCall
  end
  class RepetitionCall < ExprCall
  end
  class RepetitionOnePlusCall < ExprCall
  end

  class ApplyCall < ExprCall
    # property expr : Expr   # inherited from ExprCall
    # property pos : Int32   # inherited from ExprCall
    getter rule : Rule
    property left_recursive : Bool
    property seed_parse_tree : ParseTree?

    def initialize(apply_expr : Apply, @rule, @pos, @left_recursive = false)
      @expr = apply_expr
      @seed_parse_tree = nil
    end

    def inspect(io)
      io.print("#{self.class.name}:#{self.object_id} at #{@pos}: #{@rule.name} -> #{@rule.expr.to_s}")
    end

    # returns true if this rule application is left recursive at `@pos`; false otherwise
    def left_recursive?
      @left_recursive
    end
  end

  class Matcher
    @memoTable : Hash(Int32, Column)
    getter input : String
    property pos : Int32
    getter rules : Hash(String, Rule)
    property growing : Hash(Rule, Hash(Int32, ParseTree?))   # growing is a map <R -> <P -> seed >> from rules to maps of input positions to seeds at that input position. This is used to record the ongoing growth of a seed for a rule R at input position P.
    property expr_call_stack : Array(ExprCall)
    property fail_all_rules_until_this_rule : ApplyCall?

    def initialize(rules = {} of String => Rule)
      @rules = rules

      # these structures are necessary for handling left recursion
      @growing = {} of Rule => Hash(Int32, ParseTree?)
      @expr_call_stack = [] of ExprCall
      @fail_all_rules_until_this_rule = nil

      @input = ""
      @memoTable = {} of Int32 => Column
      @pos = 0
    end

    def add_rule(rule_name, expr : Expr)
      @rules[rule_name] = Rule.new(self, rule_name, expr)
      self
    end

    def get_rule(rule_name) : Rule
      @rules[rule_name]
    end

    # returns nil if the grammar rules don't match the full input string
    def match(input, start_rule_name = "start") : ParseTree?
      @input = input
      
      prepare_for_matching    # (re)initialize the growing map and limit set just prior to use

      start_expr = Apply.new(start_rule_name)
      parse_tree = start_expr.eval(self)
      if parse_tree
        parse_tree.recursively_populate_parents
        parse_tree if @pos == @input.size
      end
    end

    # per https://tratt.net/laurie/research/pubs/html/tratt__direct_left_recursive_parsing_expression_grammars/:
    # growing is the data structure at the heart of the algorithm. 
    # A programming language-like type for it would be Map<Rule,Map<Int,Result>>. 
    # Since we statically know all the rules for a PEG, growing is statically initialised with an 
    # empty map for each rule at the beginning of the algorithm (line 1).
    #
    # So, we want to initialize the growing map just prior to using it, since that will be the only point that we know for sure that
    # all of the rules have been added to the matcher.
    def prepare_for_matching
      @memoTable = {} of Int32 => Column

      @pos = 0

      # the next 4 lines implement line 1 of Algorithm 2 from https://tratt.net/laurie/research/pubs/html/tratt__direct_left_recursive_parsing_expression_grammars/
      @growing = {} of Rule => Hash(Int32, ParseTree?)
      @rules.each_value do |rule|
        @growing[rule] = {} of Int32 => ParseTree?
      end

      @expr_call_stack = [] of ExprCall

      @fail_all_rules_until_this_rule = nil
    end

    # returns the deepest/most-recent application of `rule` at position `pos` in the rule application stack
    def lookup_rule_application_in_call_stack(rule, pos) : ApplyCall?
      i = @expr_call_stack.size - 1
      while i >= 0
        expr_application_i = @expr_call_stack[i]
        i -= 1
        next unless expr_application_i.is_a?(ApplyCall)
        return expr_application_i if expr_application_i.rule == rule && expr_application_i.pos == pos
      end
      nil
    end

    # returns the deepest/most-recent left-recursive application of `rule` in the rule application stack
    def lookup_left_recursive_rule_application(rule) : ApplyCall?
      i = @expr_call_stack.size - 1
      while i >= 0
        expr_application_i = @expr_call_stack[i]
        i -= 1
        next unless expr_application_i.is_a?(ApplyCall)
        return expr_application_i if expr_application_i.rule == rule && expr_application_i.left_recursive?
      end
      nil
    end

    # def lookup_previous_rule_application(rule) : ApplyCall?
    #   i = @expr_call_stack.size - 1
    #   while i >= 0
    #     expr_application_i = @expr_call_stack[i]
    #     i -= 1
    #     next unless expr_application_i.is_a?(ApplyCall)
    #     return expr_application_i if expr_application_i.rule == rule
    #   end
    #   nil
    # end

    # def current_rule_being_applied : Rule?
    #   i = @expr_call_stack.size - 1
    #   while i >= 0
    #     expr_application_i = @expr_call_stack[i]
    #     i -= 1
    #     next unless expr_application_i.is_a?(ApplyCall)
    #     return expr_application_i.rule
    #   end
    #   nil
    # end

    # def left_recursive_rule_applications(rule) : Array(ApplyCall)
    #   @expr_call_stack.select {|expr_call| expr_call.is_a?(ApplyCall) && expr_call.rule == rule }.as(Array(ApplyCall))
    # end

    def fail_all_rules_back_to(previous_application_of_rule : ApplyCall)
      @fail_all_rules_until_this_rule = previous_application_of_rule
    end

    def fail_all_rules?
      !!@fail_all_rules_until_this_rule
    end

    def push_onto_call_stack(expr_application : ExprCall)
      # puts "push_onto_call_stack #{expr_application.inspect}"
      @expr_call_stack.push(expr_application)
      expr_application
    end

    def pop_off_of_call_stack() : ExprCall
      retval = @expr_call_stack.pop
      # puts "pop_off_of_call_stack -> #{retval.inspect}"
      retval
    end

    def has_memoized_result?(rule_name) : Bool
      col = @memoTable[@pos]?
      !!col && col.has_key?(rule_name)
    end

    def memoize_result(pos, rule_name, parse_tree)
      col = (@memoTable[pos] ||= {} of String => MemoResult)
      memoized_result = if parse_tree
        MemoResult.new(parse_tree, @pos)
      else
        MemoResult.new(nil)
      end
      col[rule_name] = memoized_result
    end

    def use_memoized_result(rule_name) : ParseTree?
      col = @memoTable[@pos]
      result = col[rule_name]
      if result.parse_tree
        @pos = result.nextPos
        result.parse_tree
      end
    end

    def eof?
      @pos >= @input.size
    end

    def consume(c) : Bool
      if @input[@pos] == c
        @pos += 1
        true
      else
        false
      end
    end
  end


  alias Expr = Apply | Terminal | Choice | Sequence | NegLookAhead | PosLookAhead | Optional | Repetition | RepetitionOnePlus

  # Apply represents the application of a named rule
  class Apply
    @rule_name : String
    property label : String?

    def initialize(rule_name)
      @rule_name = rule_name
    end

    def label(label : String) : Apply
      @label = label
      self
    end

    # this implements Tratt's Algorithm 2 in section 6.4 of https://tratt.net/laurie/research/pubs/html/tratt__direct_left_recursive_parsing_expression_grammars/
    def eval(matcher) : ParseTree?   # line 3 of Algorithm 2
      return nil if matcher.fail_all_rules?

      rule = matcher.get_rule(@rule_name)
      pos = matcher.pos

      # has this same rule been applied at the same position previously?
      previous_application_of_rule_at_pos = matcher.lookup_rule_application_in_call_stack(rule, pos)
      # if previous_application_of_rule_at_pos != nil, then a previous application of rule `rule` was attempted at position `pos`, 
      # so this application - once it is performed via a call to #traditional_rule_application - is going to be a left recursive 
      # application of the same rule

      is_this_application_left_recursive_at_pos = !!previous_application_of_rule_at_pos

      # look up the most recent left-recursive application of this rule, occurring at any position
      previous_left_recursive_application_of_rule = matcher.lookup_left_recursive_rule_application(rule)

      # is this rule currently in left recursion anywhere on the application call stack?
      is_rule_in_left_recursion_anywhere = !!previous_left_recursive_application_of_rule

      # if we're already in left recursion on `rule` and we have a seed growing for `rule` at `pos`, then we are in left recursion on rule `rule` at position `pos`
      is_rule_in_left_recursion_at_current_position = is_rule_in_left_recursion_anywhere && matcher.growing[rule].has_key?(pos)

      current_rule_application = push_rule_application(matcher, rule, pos, is_this_application_left_recursive_at_pos)

      retval = if is_rule_in_left_recursion_at_current_position             # line 14 of Algorithm 2 - we are in left recursion on rule `rule` at position `pos`
        seed_parse_tree = matcher.growing[rule][pos]
        if seed_parse_tree
          matcher.pos = seed_parse_tree.finishing_pos + 1
        else
          matcher.pos = pos
        end
        seed_parse_tree
      elsif is_this_application_left_recursive_at_pos                       # line 16 of Algorithm 2 - first LR call at pos - left recursive rule application, no input consumed since last application of `rule` at `pos`
        # We want to maximally grow the seed at the first occurrence of a left-recursive rule application of `rule`.
        # We want to minimally grow the seeds of all other left-recursive rule application of `rule` that occur while we are still
        # growing the seed associated with the first occurrence of a left-recursive rule application of `rule`.
        # This means that the first occurrence of left recursive seed growth for `rule` should continue until it can't grow anymore, but all
        # other occurrences of left recursive seed growth for `rule` should only grow once level and then fail.
        #
        # The rule of seed growth is:
        # Only the top-level seed growth for a given rule may allow left recursive calls; deeper-level seed growth on the
        # same rule may not be made up of any left-recursive calls.

        # Here, we are starting to grow a seed on a left-recursive call.
        # We can only grow a single seed for a given rule at a time. All other would-be seed-growths for the same rule must fail,
        # in order to ensure the left-most seed growth consumes as much as possible.
        # Therefore, if we detect that this recursive call is a top-level seed growth for `rule`, then we want to grow the seed
        # as much as we can; otherwise, we conclude that this is not a top-level seed growth, and therefore needs to fail - i.e.
        # the non-top-level seed will start as nil, but will never be updated and the first parse tree returned from the first-level, 
        # second-level, third-level, etc.-level left-recursive call will be treated as the parse tree for those left-recursive
        # calls.

        number_of_seeds_being_grown_for_rule = matcher.growing[rule]?.try(&.size) || 0
        if number_of_seeds_being_grown_for_rule == 0
          # if this is a top-level seed growth for `rule`, then do the following:
          matcher.growing[rule][pos] = nil                                  # line 17 of Algorithm 2
          while true                                                        # line 18 of Algorithm 2 - this loop switches to a Warth et al.-style iterative bottom-up parser
            # parse_tree = eval(matcher, calling_rule, calling_rule_pos)    # line 19 of Algorithm 2 - this is wrong; we need to apply the rule in traditional style instead
            matcher.pos = pos
            parse_tree = traditional_rule_application(matcher, current_rule_application)      # line 19 of Algorithm 2
            seed_parse_tree = matcher.growing[rule][pos]                    # line 20 of Algorithm 2
            if parse_tree.nil? || (seed_parse_tree && parse_tree.finishing_pos <= seed_parse_tree.finishing_pos)   # line 21 of Algorithm 2 - this condition indicates we're done growing the seed - it can't be grown any further
              matcher.growing[rule].delete(pos)                             # line 22 of Algorithm 2
              if seed_parse_tree
                matcher.pos = seed_parse_tree.finishing_pos + 1
              else
                matcher.pos = pos
              end
              
              # now that we're finished growing the seed...
              # If this rule application was left recursive, but the previous one wasn't left recursive, then we know that the parse tree
              # returned by this rule application is the seed parse tree. Since the seed is done growing, then `seed_parse_tree`
              # is what we would like for the previous (non-recursive) rule application - `previous_application_of_rule_at_pos` - to
              # return as its parse tree -- but only if the seed doesn't represent a parse error. If the seed reprsents a parse error, 
              # then we just want to return nil, like a normal failed rule application. That will bail us out of left-recursion mode, 
              # and give the rule's other alternatives a chance to match on the original non-left-recursive application of `rule`.
              # In order to do that, we're going to store the seed parse tree in the `previous_application_of_rule_at_pos`
              # so that it can return the seed parse tree, and we will make this rule application (and all intermediate rule applications 
              # that happened between this one and `previous_application_of_rule_at_pos`) fail, which will give `previous_application_of_rule_at_pos` the
              # opportunity to return the seed parse tree. Then parsing can continue as normal.
              returning_seed_parse_tree = if is_this_application_left_recursive_at_pos && 
                          previous_application_of_rule_at_pos && !previous_application_of_rule_at_pos.left_recursive?  # we know with 100% certainty that `previous_application_of_rule_at_pos` is not nil, because the only way for current_rule_application to be left_recursive (which we establish earlier in this condition) is if previous_application_of_rule_at_pos is not nil. In other words, `is_this_application_left_recursive_at_pos==true` implies `!previous_application_of_rule_at_pos.nil?`
                if seed_parse_tree
                  previous_application_of_rule_at_pos.seed_parse_tree = seed_parse_tree
                  matcher.fail_all_rules_back_to(previous_application_of_rule_at_pos)
                end
                nil
              else
                seed_parse_tree
              end
              pop_rule_application(matcher)
              if returning_seed_parse_tree
                return ApplyTree.new(returning_seed_parse_tree, @rule_name, matcher.input, pos, returning_seed_parse_tree.finishing_pos).label(@label)
              else
                return nil
              end
            end                                                             # line 24 of Algorithm 2
            matcher.growing[rule][pos] = parse_tree                         # line 25 of Algorithm 2
          end                                                               # line 26 of Algorithm 2
        else
          # otherwise, we are starting a deeper level seed growth, and we only want the seed to grow so long as it doesn't grow
          # by means of further left-recursion; so, we need to start a new seed growth with a nil seed, but we are never going
          # to update the seed, thereby ensuring that any any further left-recursion on `rule` at `pos` fails

          matcher.growing[rule][pos] = nil                                  # line 17 of Algorithm 2

          matcher.pos = pos
          seed_parse_tree = traditional_rule_application(matcher, current_rule_application)      # line 19 of Algorithm 2
          matcher.growing[rule].delete(pos)                                 # line 22 of Algorithm 2
          if seed_parse_tree
            matcher.pos = seed_parse_tree.finishing_pos + 1
          else
            matcher.pos = pos
          end
          
          if previous_application_of_rule_at_pos && !previous_application_of_rule_at_pos.left_recursive?
            if seed_parse_tree
              previous_application_of_rule_at_pos.seed_parse_tree = seed_parse_tree
              matcher.fail_all_rules_back_to(previous_application_of_rule_at_pos)
            end
            nil
          else
            seed_parse_tree
          end

        end
      else                                                                # line 27 of Algorithm 2
        traditional_rule_application(matcher, current_rule_application)   # line 33 of Algorithm 2
      end                                                                 # line 35 of Algorithm 2

      pop_rule_application(matcher)
      if retval
        ApplyTree.new(retval, @rule_name, matcher.input, pos, retval.finishing_pos).label(@label)
      end
    end                                                                   # line 36 of Algorithm 2

    def traditional_rule_application(matcher, current_rule_application) : ParseTree?
      name = @rule_name

      if matcher.has_memoized_result?(name)
        matcher.use_memoized_result(name)
      else
        # this logic captures "normal" rule application - no memoization, can't handle left recursion
        origPos = matcher.pos
        rule = matcher.rules[name]

        parse_tree = rule.expr.eval(matcher)
        # matcher.memoize_result(origPos, name, parse_tree)

        if matcher.fail_all_rules?
          if current_rule_application == matcher.fail_all_rules_until_this_rule
            # there is an assumption that if we take this branch, then this `current_rule_application` was the rule application that
            # was identified as the original non-left-recursive call of `rule`, and therefore it *must* have its seed_parse_tree
            # set with the parse tree that that matches as much of the input as a left-recursive application of `rule` at `origPos`
            # could possibly match, and therefore we want to return that seed parse tree that had been previously built up.
            matcher.fail_all_rules_until_this_rule = nil
            seed_parse_tree = current_rule_application.seed_parse_tree
            matcher.pos = seed_parse_tree.finishing_pos + 1 if seed_parse_tree
            seed_parse_tree
          else
            return nil   # we need to fail this application because `matcher.fail_all_rules?` mode is enabled
          end
        else
          parse_tree
        end
      end
    end

    def push_rule_application(matcher, rule, pos, is_this_application_left_recursive_at_pos)
      current_rule_application = ApplyCall.new(self, rule, pos, is_this_application_left_recursive_at_pos)
      matcher.push_onto_call_stack(current_rule_application)
      current_rule_application
    end

    def pop_rule_application(matcher) : ApplyCall
      expr_call = matcher.pop_off_of_call_stack
      expr_call.is_a?(ApplyCall) ? expr_call : raise "unexpected ExprCall on call stack. expected an ApplyCall."
    end

    def to_s
      "apply(#{@rule_name})"
    end
  end

  # Match string literals
  class Terminal
    @str : String
    property label : String?

    def initialize(str)
      @str = str
    end

    def label(label : String) : Terminal
      @label = label
      self
    end

    # returns String | Nil
    def eval(matcher) : ParseTree?
      return nil if matcher.fail_all_rules?

      matcher.push_onto_call_stack(TerminalCall.new(self, matcher.pos))

      orig_pos = matcher.pos
      terminal_matches = @str.each_char.all? do |c|
        if matcher.eof?
          matcher.pos = orig_pos
          matcher.pop_off_of_call_stack
          return nil
        end
        matcher.consume(c)
      end

      matcher.pop_off_of_call_stack
      if terminal_matches
        TerminalTree.new(@str, matcher.input, orig_pos, matcher.pos - 1).label(@label)
      end
    end

    def to_s
      "term(\"#{@str}\")"
    end
  end

  # Ordered choice
  class Choice
    @exps : Array(Expr)
    property label : String?

    def initialize(exps)
      @exps = exps
    end

    def label(label : String) : Choice
      @label = label
      self
    end

    def eval(matcher) : ParseTree?
      return nil if matcher.fail_all_rules?

      matcher.push_onto_call_stack(ChoiceCall.new(self, matcher.pos))

      origPos = matcher.pos
      @exps.reject {|expr| expr.is_a?(PosLookAhead) || expr.is_a?(NegLookAhead) }.each do |expr|
        if matcher.fail_all_rules?
          matcher.pop_off_of_call_stack
          return nil
        end
        matcher.pos = origPos
        parse_tree = expr.eval(matcher)
        if parse_tree
          matcher.pop_off_of_call_stack
          return ChoiceTree.new(parse_tree, matcher.input, origPos, parse_tree.finishing_pos).label(@label)
        end
      end

      matcher.pop_off_of_call_stack
      nil
    end

    def to_s
      if @exps.size > 1
        "(#{@exps.map(&.to_s).join(" | ")})"
      else
        @exps.first.to_s
      end
    end
  end

  class Sequence
    @exps : Array(Expr)
    property label : String?

    def initialize(exps)
      @exps = exps
    end

    def label(label : String) : Sequence
      @label = label
      self
    end

    # returns Array(ParseTree) | Nil
    def eval(matcher) : ParseTree?
      return nil if matcher.fail_all_rules?

      matcher.push_onto_call_stack(SequenceCall.new(self, matcher.pos))

      ans = [] of ParseTree
      start_pos = matcher.pos

      @exps.each do |expr|
        parse_tree = expr.eval(matcher)
        if parse_tree.nil? || matcher.fail_all_rules?
          matcher.pos = start_pos
          matcher.pop_off_of_call_stack
          return nil
        end
        ans.push(parse_tree) unless expr.is_a?(NegLookAhead) || expr.is_a?(PosLookAhead)
      end

      matcher.pop_off_of_call_stack
      SequenceTree.new(ans, matcher.input, start_pos, matcher.pos - 1).label(@label)
    end

    def to_s
      if @exps.size > 1
        "(#{@exps.map(&.to_s).join(" ")})"
      else
        @exps.first.to_s
      end
    end
  end

  # Non-consuming negative lookahead match of e
  class NegLookAhead
    @exp : Expr
    property label : String?

    def initialize(exp)
      @exp = exp
    end

    def label(label : String) : NegLookAhead
      @label = label
      self
    end

    # this should return true if the expr does not match, and nil otherwise; do not return false, because nil indicates parse failure
    def eval(matcher) : ParseTree?
      return nil if matcher.fail_all_rules?

      matcher.push_onto_call_stack(NegLookAheadCall.new(self, matcher.pos))

      origPos = matcher.pos
      expr_does_not_match = !@exp.eval(matcher)
      matcher.pos = origPos
      matcher.pop_off_of_call_stack
      return nil if matcher.fail_all_rules?
      NegLookAheadTree.new(expr_does_not_match, matcher.input, origPos).label(@label) if expr_does_not_match
    end

    def to_s
      "!#{@exp.to_s}"
    end
  end

  # Non-consuming positive lookahead match of e
  class PosLookAhead
    @exp : Expr
    property label : String?

    def initialize(exp)
      @exp = exp
    end

    def label(label : String) : PosLookAhead
      @label = label
      self
    end

    # this should return true if the expr matches, and nil otherwise; do not return false, because nil indicates parse failure
    def eval(matcher) : ParseTree?
      return nil if matcher.fail_all_rules?

      matcher.push_onto_call_stack(PosLookAheadCall.new(self, matcher.pos))

      origPos = matcher.pos
      expr_matches = !!@exp.eval(matcher)
      matcher.pos = origPos
      matcher.pop_off_of_call_stack
      return nil if matcher.fail_all_rules?
      PosLookAheadTree.new(expr_matches, matcher.input, origPos).label(@label) if expr_matches
    end

    def to_s
      "&#{@exp.to_s}"
    end
  end

  class Optional
    @exp : Expr
    property label : String?

    def initialize(exp)
      @exp = exp
    end

    def label(label : String) : Optional
      @label = label
      self
    end

    # returns Array(ParseTree) | Nil
    def eval(matcher) : ParseTree?
      return nil if matcher.fail_all_rules?

      matcher.push_onto_call_stack(OptionalCall.new(self, matcher.pos))

      parse_tree = nil

      origPos = matcher.pos
      tmp_parse_tree = @exp.eval(matcher)
      if tmp_parse_tree
        parse_tree = tmp_parse_tree unless tmp_parse_tree.is_a?(NegLookAheadTree) || tmp_parse_tree.is_a?(PosLookAheadTree)
      else
        matcher.pos = origPos
      end

      matcher.pop_off_of_call_stack

      return nil if matcher.fail_all_rules?

      OptionalTree.new(parse_tree, matcher.input, origPos, matcher.pos - 1).label(@label)
    end

    def to_s
      "#{@exp.to_s}?"
    end
  end

  # this represents the kleene star operator - 0+ repetitions
  class Repetition
    @exp : Expr
    property label : String?

    def initialize(exp)
      @exp = exp
    end

    def label(label : String) : Repetition
      @label = label
      self
    end

    # returns Array(ParseTree) | Nil
    def eval(matcher) : ParseTree?
      return nil if matcher.fail_all_rules?

      matcher.push_onto_call_stack(RepetitionCall.new(self, matcher.pos))
      
      start_pos = matcher.pos

      ans = [] of ParseTree
      loop do
        origPos = matcher.pos
        parse_tree = @exp.eval(matcher)
        if parse_tree
          if matcher.fail_all_rules?
            matcher.pop_off_of_call_stack
            return nil
          end
          ans.push(parse_tree) unless @exp.is_a?(NegLookAhead) || @exp.is_a?(PosLookAhead)
        else
          matcher.pos = origPos
          if matcher.fail_all_rules?
            matcher.pop_off_of_call_stack
            return nil
          end
          break
        end
      end
      matcher.pop_off_of_call_stack
      RepetitionTree.new(ans, matcher.input, start_pos, matcher.pos - 1).label(@label)
    end

    def to_s
      "#{@exp.to_s}*"
    end
  end

  # this represents 1+ repetitions
  class RepetitionOnePlus
    @exp : Expr
    property label : String?

    def initialize(exp)
      @exp = exp
    end

    def label(label : String) : RepetitionOnePlus
      @label = label
      self
    end

    # returns Array(ParseTree) | Nil
    def eval(matcher) : ParseTree?
      return nil if matcher.fail_all_rules?

      matcher.push_onto_call_stack(RepetitionCall.new(self, matcher.pos))

      ans = [] of ParseTree
      start_pos = matcher.pos

      loop do
        origPos = matcher.pos
        parse_tree = @exp.eval(matcher)
        if parse_tree
          if matcher.fail_all_rules?
            matcher.pop_off_of_call_stack
            return nil
          end
          ans.push(parse_tree) unless @exp.is_a?(NegLookAhead) || @exp.is_a?(PosLookAhead)
        else
          matcher.pos = origPos
          if matcher.fail_all_rules?
            matcher.pop_off_of_call_stack
            return nil
          end
          break
        end
      end

      matcher.pop_off_of_call_stack
      if ans.size >= 1
        RepetitionTree.new(ans, matcher.input, start_pos, matcher.pos - 1).label(@label)
      else
        matcher.pos = start_pos
        nil
      end
    end

    def to_s
      "#{@exp.to_s}+"
    end
  end

end