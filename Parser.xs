/* $Id: Parser.xs,v 2.49 1999/11/30 13:43:48 gisle Exp $
 *
 * Copyright 1999, Gisle Aas.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the same terms as Perl itself.
 */

/* TODO:
 *   - write test scritps
 *   - write documentation
 *   - callback parameter spec
 *   - pic attribute (">" or "?>" are defaults)
 *   - count chars, line numbers
 *   - utf8 mode (entities expand to utf8 chars)
 *   - return partial text from literal/cdata mode
 *   - option to avoid attribute value decoding
 *
 * PLAIN BUGS:
 *   - unbroken_text does not handle cdata sections.
 *
 * POSSIBLE OPTIMIZATIONS:
 *   - direct method calls
 *   - avoid building start tag tokens when start tags are
 *     ignored.
 *   - less need for leaving things in buf when unbroken_text
 *     option is enabled.
 *
 * MINOR "BUGS" (alias FEATURES):
 *   - no way to clear "bool_attr_val" which gives the name of
 *     the attribute as value.  Perhaps not really a problem.
 *   - <plaintext> should not end with </plaintext>; can't be
 *     escaped.
 *   - xml_mode should demand ";" at end of entity references
 */

/* #define MARKED_SECTION /**/

#ifdef __cplusplus
extern "C" {
#endif
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#ifdef __cplusplus
}
#endif

#include "patchlevel.h"
#if PATCHLEVEL <= 4 /* perl5.004 */

#ifndef PL_sv_undef
   #define PL_sv_undef sv_undef
   #define PL_sv_yes   sv_yes
#endif

#ifndef PL_hexdigit
   #define PL_hexdigit hexdigit
#endif

#if (PATCHLEVEL == 4 && SUBVERSION <= 4)
/* The newSVpvn function was introduced in perl5.004_05 */
static SV *
newSVpvn(char *s, STRLEN len)
{
    register SV *sv = newSV(0);
    sv_setpvn(sv,s,len);
    return sv;
}
#endif
#endif /* perl5.004 */

#define P_MAGIC 0x16091964

enum event_id {
  E_DECLARATION = 0,
  E_COMMENT,
  E_START,
  E_END,
  E_TEXT,
  E_PROCESS,
  E_DEFAULT,
  /**/
  EVENT_COUNT,
};
typedef enum event_id event_id_t;

#include "hctype.h" /* isH...() macros */
#include "tokenpos.h"

#ifdef MARKED_SECTION
enum marked_section_t {
  MS_NONE = 0,
  MS_INCLUDE,
  MS_RCDATA,
  MS_CDATA,
  MS_IGNORE,
};
#endif

struct p_handler {
  SV* cb;
  SV* attrspec;
};

struct p_state {
  U32 magic;

  SV* buf;
  SV* pending_text;

  /* various boolean configuration attributes */
  bool strict_comment;
  bool strict_names;
  bool xml_mode;
  bool unbroken_text;

  /* special parsing modes */
  char* literal_mode;

#ifdef MARKED_SECTION
  /* marked section support */
  enum marked_section_t ms;
  AV* ms_stack;
  bool marked_sections;
#endif

  /* various */
  SV* bool_attr_val;
  struct p_handler handlers[EVENT_COUNT];
};
typedef struct p_state PSTATE;


static
struct literal_tag {
  int len;
  char* str;
}
literal_mode_elem[] =
{
  {6, "script"},
  {5, "style"},
  {3, "xmp"},
  {9, "plaintext"},
  {0, 0}
};

static HV* entity2char;  /* %HTML::Entities::entity2char */

static SV*
sv_lower(SV* sv)
{
   STRLEN len;
   char *s = SvPV_force(sv, len);
   for (; len--; s++)
	*s = toLOWER(*s);
   return sv;
}

static SV*
decode_entities(SV* sv, HV* entity2char)
{
  STRLEN len;
  char *s = SvPV_force(sv, len);
  char *t = s;
  char *end = s + len;
  char *ent_start;

  char *repl;
  STRLEN repl_len;
  char buf[1];
  

  while (s < end) {
    assert(t <= s);

    if ((*t++ = *s++) != '&')
      continue;

    ent_start = s;
    repl = 0;

    if (*s == '#') {
      int num = 0;
      /* currently this code is limited to numeric references with values
       * below 256.  Doing more need Unicode support.
       */

      s++;
      if (*s == 'x' || *s == 'X') {
	char *tmp;
	s++;
	while (*s) {
	  char *tmp = strchr(PL_hexdigit, *s);
	  if (!tmp)
	    break;
	  s++;
	  if (num < 256) {
	    num = num << 4 | ((tmp - PL_hexdigit) & 15);
	  }
	}
      }
      else {
	while (isDIGIT(*s)) {
	  if (num < 256)
	    num = num*10 + (*s - '0');
	  s++;
	}
      }
      if (num && num < 256) {
	buf[0] = num;
	repl = buf;
	repl_len = 1;
      }
    }
    else {
      char *ent_name = s;
      while (isALNUM(*s))
	s++;
      if (ent_name != s && entity2char) {
	SV** svp = hv_fetch(entity2char, ent_name, s - ent_name, 0);
	if (svp)
	  repl = SvPV(*svp, repl_len);
      }
    }

    if (repl) {
      if (*s == ';')
	s++;
      t--;  /* '&' already copied, undo it */
      if (t + repl_len > s)
	croak("Growing string not supported yet");
      while (repl_len--)
	*t++ = *repl++;
    }
    else {
      while (ent_start < s)
	*t++ = *ent_start++;
    }
  }

  if (t != s) {
    *t = '\0';
    SvCUR_set(sv, t - SvPVX(sv));
  }
  return sv;
}

static void
html_handle(PSTATE* p_state,
	    event_id_t event,
	    char *beg, char *end,
	    token_pos_t *tokens, int num_tokens,
	    SV* self
	    )
{
  struct p_handler *h = &p_state->handlers[event];

  if (0) {
    char *s = beg;
    int i;

    /* print debug output */
    switch(event) {
    case E_DECLARATION: printf("DECLARATION"); break;
    case E_COMMENT:     printf("COMMENT"); break;
    case E_START:       printf("START"); break;
    case E_END:         printf("END"); break;
    case E_TEXT:        printf("TEXT"); break;
    case E_PROCESS:     printf("PROCESS"); break;
    default:            printf("EVENT #%d", event); break;
    }

    printf(" [");
    while (s < end) {
      if (*s == '\n') {
	putchar('\\'); putchar('n');
      }
      else
	putchar(*s);
      s++;
    }
    printf("] %d\n", end - beg);
    for (i = 0; i < num_tokens; i++) {
      printf("  token %d: %d %d\n",
	     i,
	     tokens[i].beg - beg,
	     tokens[i].end - tokens[i].beg);
    }
  }

  if (!h->cb || !SvOK(h->cb)) {
    event = E_DEFAULT;
    h = &p_state->handlers[E_DEFAULT];
    if (!h->cb || !SvOK(h->cb))
      return;
  }

  if (1) {
    dSP;
    STRLEN my_na;
    char *attrspec = SvPV(h->attrspec, my_na);

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);

    for (; *attrspec; attrspec++) {
      SV* arg = 0;
      switch(*attrspec) {
      case 's':
	arg = self;
	break;

      case 't':
	/* tokens arrayref */
	{
	  AV* av = newAV();
	  int i;
	  for (i = 0; i < num_tokens; i++) {
	    av_push(av, newSVpvn(tokens[i].beg, tokens[i].end-tokens[i].beg));
	  }
	  arg = newRV_noinc((SV*)av);
	}
	break;

      case '#':
	/* tokenpos arrayref */
	{
	  AV* av = newAV();
	  int i;
	  for (i = 0; i < num_tokens; i++) {
	    av_push(av, newSViv(tokens[i].beg-beg));
	    av_push(av, newSViv(tokens[i].end-tokens[i].beg));
	  }
	  arg = newRV_noinc((SV*)av);
	}
	break;

      case 'n':
	/* tagname */
	if (num_tokens >= 1) {
	  arg = sv_2mortal(newSVpvn(tokens[0].beg, tokens[0].end - tokens[0].beg));
	  if (!p_state->xml_mode)
	    sv_lower(arg);
	}
	break;

      case 'a':
	/* attr_hashref */
	if (event == E_START) {
	  HV* hv = newHV();
	  int i;
	  for (i = 1; i < num_tokens; i += 2) {
	    SV* attrname = newSVpvn(tokens[i].beg,
				    tokens[i].end-tokens[i].beg);
	    SV* attrval;
	    if (p_state->bool_attr_val && tokens[i].beg == tokens[i+1].beg) {
	      attrval = newSVsv(p_state->bool_attr_val);
	    }
	    else {
	      char *beg = tokens[i+1].beg;
	      STRLEN len = tokens[i+1].end - beg;
	      if (*beg == '"' || *beg == '\'') {
		beg++; len -= 2;
	      }
	      attrval = newSVpvn(beg, len);
	      decode_entities(attrval, entity2char);
	    }
	    
	    if (!p_state->xml_mode)
	      sv_lower(attrname);
	    hv_store_ent(hv, attrname, attrval, 0);
	  }
	  arg = newRV_noinc((SV*)hv);
	}
	break;

      case 'A':
	/* attrseq arrayref (v2 compatibility stuff) */
	if (event == E_START) {
	  AV* av = newAV();
	  int i;
	  for (i = 1; i < num_tokens; i += 2) {
	    SV* attrname = newSVpvn(tokens[i].beg, tokens[i].end-tokens[i].beg);
	    if (!p_state->xml_mode)
	      sv_lower(attrname);
	    av_push(av, attrname);
	  }
	  arg = newRV_noinc((SV*)av);
	}
	break;
	
      case 'd':
	/* origtext, data */
	arg = sv_2mortal(newSVpvn(beg, end - beg));
	break;

      case 'D':
	/* decoded text */
	if (event == E_TEXT) {
	  arg = sv_2mortal(newSVpvn(beg, end - beg));
	  if (!p_state->literal_mode || p_state->ms == MS_CDATA)
	    decode_entities(arg, entity2char);
	}
	break;

      case 'L':
	/* literal */
	{
	  int len = attrspec[1];
	  arg = sv_2mortal(newSVpvn(attrspec+2, len));
	  attrspec += len + 1;
	}
	break;

      default:
	arg = sv_2mortal(newSVpvn(attrspec, 1));
	break;
      }

      if (!arg)
	arg = &PL_sv_undef;

      XPUSHs(arg);
    }

    PUTBACK;
  
    perl_call_sv(h->cb, G_DISCARD | G_VOID);

    FREETMPS;
    LEAVE;
  }

}

#if 0 /*********************************************************/

static void
html_default(PSTATE* p_state, char* beg, char *end, SV* self)
{	
  SV *cb = p_state->default_cb;
  if (beg == end)
    return;

  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
    
  }
}

static void
html_text(PSTATE* p_state, char* beg, char *end, int cdata, SV* self)
{
  AV *accum = p_state->accum;
  SV *cb = p_state->text_cb;

  SV* text;

  if (beg == end)
    return;

#ifdef MARKED_SECTION
  if (p_state->ms == MS_IGNORE)
    return;
#endif

  if (!accum && !cb) {
    html_default(p_state, beg, end, self);
    return;
  }

  if (p_state->unbroken_text) {
    if (p_state->pending_text)
      sv_catpvn(p_state->pending_text, beg, end - beg);
    else
      p_state->pending_text = newSVpvn(beg, end - beg);
    return;
  }

  text = newSVpvn(beg, end - beg);
  if (!cdata && p_state->decode_text_entities) {
    decode_entities(text, entity2char);
    cdata++;
  }

  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("T", 1));
    av_push(av, text);
    if (cdata)
      av_push(av, newSVsv(&PL_sv_yes));
    av_push(accum, newRV_noinc((SV*)av));
    return;
  }

  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    XPUSHs(sv_2mortal(text));
    XPUSHs(boolSV(cdata));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
}


static void
flush_pending_text(PSTATE* p_state, SV* self)
{
  char *s;
  STRLEN len;
  bool old_unbroken_text;

  if (!p_state->pending_text)
    return;
  old_unbroken_text = p_state->unbroken_text;
  p_state->unbroken_text = 0;
  s = SvPV(p_state->pending_text, len);
  html_text(p_state, s, s+len, 0, self);
  SvREFCNT_dec(p_state->pending_text);
  p_state->pending_text = 0;
  p_state->unbroken_text = old_unbroken_text;
  return;
}


static void
html_end(PSTATE* p_state,
	 char *tag_beg, char *tag_end,
	 char *beg, char *end,
	 SV* self)
{
  AV *accum;
  SV *cb;

#ifdef MARKED_SECTION
  if (p_state->ms == MS_IGNORE)
    return;
#endif

  flush_pending_text(p_state, self);

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    SV* tag = newSVpv(tag_beg, tag_end - tag_beg);
    if (!p_state->keep_case && !p_state->xml_mode)
      sv_lower(tag);
    
    av_push(av, newSVpv("E", 1));
    av_push(av, tag);
    av_push(av, newSVpvn(beg, end - beg));
    av_push(accum, newRV_noinc((SV*)av));
    return;
  }

  cb = p_state->end_cb;
  if (cb) {
    SV *sv;
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    sv = sv_2mortal(newSVpv(tag_beg, tag_end - tag_beg));
    if (!p_state->keep_case && !p_state->xml_mode)
      sv_lower(sv);
    XPUSHs(sv);
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
    return;
  }

  html_default(p_state, beg, end, self);
}


static void
html_start(PSTATE* p_state,
	   char *tag_beg, char *tag_end,
	   AV* tokens,
	   int empty_tag,
	   char *beg, char *end,
	   SV* self)
{
  AV *accum = p_state->accum;
  SV *cb = p_state->start_cb;

  HV *attr;
  AV *attr_seq;

#ifdef MARKED_SECTION
  if (p_state->ms == MS_IGNORE)
    return;
#endif

  flush_pending_text(p_state, self);

  if ((accum || cb) && p_state->v2_compat) {
    /* need to construct an attr hash and an attr_seq array */
    int i;
    int len = av_len(tokens);
    attr = newHV();
    attr_seq = newAV();
    for (i = 0; i <= len; i += 2) {
      SV** svp1 = av_fetch(tokens, i,   0);
      SV** svp2 = av_fetch(tokens, i+1, 0);
      if (svp1) {
	av_push(attr_seq, SvREFCNT_inc(*svp1));
	if (svp2)
	  if (!hv_store_ent(attr, *svp1, SvREFCNT_inc(*svp2), 0))
	    SvREFCNT_dec(*svp2);
      }
    }
  }

  if (accum) {
    AV* av = newAV();
    SV* tag = newSVpv(tag_beg, tag_end - tag_beg);
    if (!p_state->keep_case && !p_state->xml_mode)
      sv_lower(tag);
    
    av_push(av, newSVpv("S", 1));
    av_push(av, tag);
    if (p_state->v2_compat) {
      av_push(av, newRV_noinc((SV*)attr));
      av_push(av, newRV_noinc((SV*)attr_seq));
    }
    else {
      av_push(av, newRV_inc((SV*)tokens));
    }
    av_push(av, newSVpv(beg, end - beg));
    av_push(accum, newRV_noinc((SV*)av));
  }
  else if (cb) {
    SV *sv;
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    sv = sv_2mortal(newSVpv(tag_beg, tag_end - tag_beg));
    if (!p_state->keep_case && !p_state->xml_mode)
      sv_lower(sv);
    XPUSHs(sv);
    if (p_state->v2_compat) {
      XPUSHs(sv_2mortal(newRV_noinc((SV*)attr)));
      XPUSHs(sv_2mortal(newRV_noinc((SV*)attr_seq)));
    }
    else {
      XPUSHs(sv_2mortal(newRV_inc((SV*)tokens)));
    }
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
  else {
    html_default(p_state, beg, end, self);
    return;
  }

  if (empty_tag)
    html_end(p_state, tag_beg, tag_end, tag_beg, tag_beg, self);
}


static void
html_process(PSTATE* p_state,
	     char *pi_beg, char *pi_end,
	     char *beg, char *end,
	     SV* self)
{
  AV *accum;
  SV *cb;

#ifdef MARKED_SECTION
  if (p_state->ms == MS_IGNORE)
    return;
#endif

  flush_pending_text(p_state, self);

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("PI", 2));
    av_push(av, newSVpvn(pi_beg, pi_end - pi_beg));
    av_push(av, newSVpvn(beg, end - beg));
    av_push(accum, newRV_noinc((SV*)av));
    return;
  }

  cb = p_state->pi_cb;
  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    XPUSHs(sv_2mortal(newSVpvn(pi_beg, pi_end - pi_beg)));
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
    return;
  }

  html_default(p_state, beg, end, self);
}


static void
html_comment(PSTATE* p_state, char *beg, char *end, SV* self)
{
  AV *accum;
  SV *cb;

#ifdef MARKED_SECTION
  if (p_state->ms == MS_IGNORE)
    return;
#endif

  flush_pending_text(p_state, self);

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("C", 1));
    av_push(av, newSVpvn(beg, end - beg));
    av_push(accum, newRV_noinc((SV*)av));
    return;
  }

  cb = p_state->com_cb;
  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
}


static void
html_decl(PSTATE* p_state, AV* tokens, char *beg, char *end, SV* self)
{
  AV *accum;
  SV *cb;

#ifdef MARKED_SECTION
  if (p_state->ms == MS_IGNORE)
    return;
#endif

  flush_pending_text(p_state, self);

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("D", 1));
    if (!p_state->v2_compat)
      av_push(av, newRV_inc((SV*)tokens));
    av_push(av, newSVpv(beg, end - beg));
    av_push(accum, newRV_noinc((SV*)av));
    return;
  }

  cb = p_state->decl_cb;
  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    if (!p_state->v2_compat)
      XPUSHs(sv_2mortal(newRV_inc((SV*)tokens)));
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
    return;
  }

  html_default(p_state, beg-2, end+1, self);
}

#endif /*********************************************************/



static char*
html_parse_comment(PSTATE* p_state, char *beg, char *end, SV* self)
{
  char *s = beg;

  if (p_state->strict_comment) {
    dTOKENS(4);
    char *start_com = s;  /* also used to signal inside/outside */

    while (1) {
      /* try to locate "--" */
    FIND_DASH_DASH:
      /* printf("find_dash_dash: [%s]\n", s); */
      while (s < end && *s != '-' && *s != '>')
	s++;

      if (s == end) {
	FREE_TOKENS;
	return beg;
      }

      if (*s == '>') {
	s++;
	if (start_com)
	  goto FIND_DASH_DASH;

	/* we are done recognizing all comments, make callbacks */
	html_handle(p_state, E_COMMENT,
		    beg - 4, s,
		    tokens, num_tokens,
		    self);
	FREE_TOKENS;

	return s;
      }

      s++;
      if (s == end) {
	FREE_TOKENS;
	return beg;
      }

      if (*s == '-') {
	/* two dashes in a row seen */
	s++;
	/* do something */
	if (start_com) {
	  PUSH_TOKEN(start_com, s-2);
	  start_com = 0;
	}
	else {
	  start_com = s;
	}
      }
    }
  }

  else { /* non-strict comment */
    token_pos_t token_pos;
    token_pos.beg = beg;
    /* try to locate /--\s*>/ which signals end-of-comment */
  LOCATE_END:
    while (s < end && *s != '-')
      s++;
    token_pos.end = s;
    if (s < end) {
      s++;
      if (*s == '-') {
	s++;
	while (isHSPACE(*s))
	  s++;
	if (*s == '>') {
	  s++;
	  /* yup */
	  html_handle(p_state, E_COMMENT, beg-4, s, &token_pos, 1, self);
	  return s;
	}
      }
      if (s < end) {
	s = token_pos.end + 2;
	goto LOCATE_END;
      }
    }
    
    if (s == end)
      return beg;
  }

  return 0;
}

#ifdef MARKED_SECTION

static void
marked_section_update(PSTATE* p_state)
{
  /* we look at p_state->ms_stack to determine p_state->ms */
  AV* ms_stack = p_state->ms_stack;
  p_state->ms = MS_NONE;

  if (ms_stack) {
    int i;
    int stack_len = av_len(ms_stack);
    int stack_idx;
    for (stack_idx = 0; stack_idx <= stack_len; stack_idx++) {
      SV** svp = av_fetch(ms_stack, stack_idx, 0);
      if (svp) {
	AV* tokens = (AV*)SvRV(*svp);
	int tokens_len = av_len(tokens);
	int i;
	assert(SvTYPE(tokens) == SVt_PVAV);
	for (i = 0; i <= tokens_len; i++) {
	  SV** svp = av_fetch(tokens, i, 0);
	  if (svp) {
	    STRLEN len;
	    char *token_str = SvPV(*svp, len);
	    enum marked_section_t token;
	    if (strEQ(token_str, "include"))
	      token = MS_INCLUDE;
	    else if (strEQ(token_str, "rcdata"))
	      token = MS_RCDATA;
	    else if (strEQ(token_str, "cdata"))
	      token = MS_CDATA;
	    else if (strEQ(token_str, "ignore"))
	      token = MS_IGNORE;
	    else
	      token = MS_NONE;
	    if (p_state->ms < token)
	      p_state->ms = token;
	  }
	}
      }
    }
  }
  /* printf("MS %d\n", p_state->ms); */
  return;
}


static char*
html_parse_marked_section(PSTATE* p_state, char *beg, char *end, SV* self)
{
  char *s = beg;
  AV* tokens = 0;

  if (!p_state->marked_sections)
    return 0;

 FIND_NAMES:
  while (isHSPACE(*s))
    s++;
  while (isHNAME_FIRST(*s)) {
    char *name_start = s;
    char *name_end;
    s++;
    while (isHNAME_CHAR(*s))
      s++;
    name_end = s;
    while (isHSPACE(*s))
      s++;
    if (s == end)
      goto PREMATURE;

    if (!tokens)
      tokens = newAV();
    av_push(tokens, sv_lower(newSVpvn(name_start, name_end - name_start)));
  }
  if (*s == '-') {
    s++;
    if (*s == '-') {
      /* comment */
      s++;
      while (1) {
	while (s < end && *s != '-')
	  s++;
	if (s == end)
	  goto PREMATURE;

	s++;  /* skip first '-' */
	if (*s == '-') {
	  s++;
	  /* comment finished */
	  goto FIND_NAMES;
	}
      }      
    }
    else
      goto FAIL;
      
  }
  if (*s == '[') {
    s++;
    /* yup */

    if (!tokens) {
      tokens = newAV();
      av_push(tokens, newSVpvn("include", 7));
    }

    if (!p_state->ms_stack)
      p_state->ms_stack = newAV();
    av_push(p_state->ms_stack, newRV_noinc((SV*)tokens));
    marked_section_update(p_state);
    return s;
  }

 FAIL:
  SvREFCNT_dec(tokens);
  return 0; /* not yet implemented */
  
 PREMATURE:
  SvREFCNT_dec(tokens);
  return beg;
}
#endif

static char*
html_parse_decl(PSTATE* p_state, char *beg, char *end, SV* self)
{
  char *s = beg + 2;

  if (*s == '-') {
    /* comment? */

    char *tmp;
    s++;
    if (s == end)
      return beg;

    if (*s != '-')
      return 0;  /* nope, illegal */

    /* yes, two dashes seen */
    s++;

    tmp = html_parse_comment(p_state, s, end, self);
    return (tmp == s) ? beg : tmp;
  }

#ifdef MARKED_SECTION
  if (*s == '[') {
    /* marked section */
    char *tmp;
    s++;
    tmp = html_parse_marked_section(p_state, s, end, self);
    return (tmp == s) ? beg : tmp;
  }
#endif

  if (*s == '>') {
    /* make <!> into empty comment <SGML Handbook 36:32> */
    token_pos_t empty;
    empty.beg = s;
    empty.end = s;
    s++;
    html_handle(p_state, E_COMMENT, beg, s, &empty, 1, self);
    return s;
  }

  if (isALPHA(*s)) {
    dTOKENS(8);

    s++;
    /* declaration */
    while (s < end && isHNAME_CHAR(*s))
      s++;
    /* first word available */
    PUSH_TOKEN(beg+2, s);

    while (s < end && isHSPACE(*s)) {
      s++;
      while (s < end && isHSPACE(*s))
	s++;

      if (s == end)
	goto PREMATURE;

      if (*s == '"' || *s == '\'') {
	char *str_beg = s;
	s++;
	while (s < end && *s != *str_beg)
	  s++;
	if (s == end)
	  goto PREMATURE;
	s++;
	PUSH_TOKEN(str_beg, s);
      }
      else if (*s == '-') {
	/* comment */
	char *com_beg = s;
	s++;
	if (s == end)
	  goto PREMATURE;
	if (*s != '-')
	  goto FAIL;
	s++;

	while (1) {
	  while (s < end && *s != '-')
	    s++;
	  if (s == end)
	    goto PREMATURE;
	  s++;
	  if (s == end)
	    goto PREMATURE;
	  if (*s == '-') {
	    s++;
	    PUSH_TOKEN(com_beg, s);
	    break;
	  }
	}
      }
      else if (*s != '>') {
	/* plain word */
	char *word_beg = s;
	s++;
	while (s < end && isHNOT_SPACE_GT(*s))
	  s++;
	if (s == end)
	  goto PREMATURE;
	PUSH_TOKEN(word_beg, s);
      }
      else {
	break;
      }
    }

    if (s == end)
      goto PREMATURE;
    if (*s == '>') {
      s++;
      html_handle(p_state, E_DECLARATION, beg, s, tokens, num_tokens, self);
      FREE_TOKENS;
      return s;
    }

  FAIL:
    FREE_TOKENS;
    return 0;

  PREMATURE:
    FREE_TOKENS;
    return beg;

  }
  return 0;
}


static char*
html_parse_start(PSTATE* p_state, char *beg, char *end, SV* self)
{
  char *s = beg;
  SV* attr;
  int empty_tag = 0;  /* XML feature */
  dTOKENS(16);

  hctype_t tag_name_first, tag_name_char;
  hctype_t attr_name_first, attr_name_char;

  if (p_state->strict_names || p_state->xml_mode) {
    tag_name_first = attr_name_first = HCTYPE_NAME_FIRST;
    tag_name_char  = attr_name_char  = HCTYPE_NAME_CHAR;
  }
  else {
    tag_name_first = tag_name_char = HCTYPE_NOT_SPACE_GT;
    attr_name_first = HCTYPE_NOT_SPACE_GT;
    attr_name_char  = HCTYPE_NOT_SPACE_EQ_GT;
  }


  assert(beg[0] == '<' && isHNAME_FIRST(beg[1]) && end - beg > 2);
  s += 2;

  while (s < end && isHCTYPE(*s, tag_name_char))
    s++;
  PUSH_TOKEN(beg+1, s);  /* tagname */

  while (isHSPACE(*s))
    s++;
  if (s == end)
    goto PREMATURE;

  while (isHCTYPE(*s, attr_name_first)) {
    /* attribute */
    char *attr_name_beg = s;
    char *attr_name_end;
    s++;
    while (s < end && isHCTYPE(*s, attr_name_char))
      s++;
    if (s == end)
      goto PREMATURE;

    attr_name_end = s;
    PUSH_TOKEN(attr_name_beg, attr_name_end); /* attr name */

    while (isHSPACE(*s))
      s++;
    if (s == end)
      goto PREMATURE;

    if (*s == '=') {
      /* with a value */
      s++;
      while (isHSPACE(*s))
	s++;
      if (s == end)
	goto PREMATURE;
      if (*s == '>') {
	/* parse it similar to ="" */
	PUSH_TOKEN(s, s);
	break;
      }
      if (*s == '"' || *s == '\'') {
	char *str_beg = s;
	s++;
	while (s < end && *s != *str_beg)
	  s++;
	if (s == end)
	  goto PREMATURE;
	s++;
	PUSH_TOKEN(str_beg, s);
      }
      else {
	char *word_start = s;
	while (s < end && isHNOT_SPACE_GT(*s)) {
	  if (p_state->xml_mode && *s == '/')
	    break;
	  s++;
	}
	if (s == end)
	  goto PREMATURE;
	PUSH_TOKEN(word_start, s);
      }
      while (isHSPACE(*s))
	s++;
      if (s == end)
	goto PREMATURE;
    }
    else {
      PUSH_TOKEN(attr_name_beg, attr_name_end); /* boolean attr value */
    }
  }

  if (p_state->xml_mode && *s == '/') {
    s++;
    if (s == end)
      goto PREMATURE;
    empty_tag = 1;
  }

  if (*s == '>') {
    s++;
    /* done */
    html_handle(p_state, E_START, beg, s, tokens, num_tokens, self);
    if (empty_tag)
      html_handle(p_state, E_END, beg, s, tokens, 1, self);
    FREE_TOKENS;

    if (1) {
      /* find out if this start tag should put us into literal_mode
       */
      int i;
      int tag_len = tokens[0].end - tokens[0].beg;

      for (i = 0; literal_mode_elem[i].len; i++) {
	if (tag_len == literal_mode_elem[i].len) {
	  /* try to match it */
	  char *s = beg + 1;
	  char *t = literal_mode_elem[i].str;
	  int len = tag_len;
	  while (len) {
	    if (toLOWER(*s) != *t)
	      break;
	    s++;
	    t++;
	    if (!--len) {
	      /* found it */
	      p_state->literal_mode = literal_mode_elem[i].str;
	      /* printf("Found %s\n", p_state->literal_mode); */
	      goto END_OF_LITERAL_SEARCH;
	    }
	  }
	}
      }
    END_OF_LITERAL_SEARCH:
    }

    return s;
  }
  
  FREE_TOKENS;
  return 0;

 PREMATURE:
  FREE_TOKENS;
  return beg;
}

static char*
html_parse_end(PSTATE* p_state, char *beg, char *end, SV* self)
{
  char *s = beg+2;
  hctype_t name_first, name_char;

  if (p_state->strict_names) {
    name_first = HCTYPE_NAME_FIRST;
    name_char  = HCTYPE_NAME_CHAR;
  }
  else {
    name_first = name_char = HCTYPE_NOT_SPACE_GT;
  }

  if (isHCTYPE(*s, name_first)) {
    token_pos_t tagname;
    tagname.beg = s;
    s++;
    while (s < end && isHCTYPE(*s, name_char))
      s++;
    tagname.end = s;
    while (isHSPACE(*s))
      s++;
    if (s < end) {
      if (*s == '>') {
	s++;
	/* a complete end tag has been recognized */
	html_handle(p_state, E_END, beg, s, &tagname, 1, self);
	return s;
      }
    }
    else {
      return beg;
    }
  }
  return 0;
}

static char*
html_parse_process(PSTATE* p_state, char *beg, char *end, SV* self)
{
  char *s = beg + 2;
  /* processing instruction */
  token_pos_t token_pos;
  token_pos.beg = s;

 FIND_PI_END:
  while (s < end && *s != '>')
    s++;
  if (*s == '>') {
    token_pos.end = s;
    s++;

    if (p_state->xml_mode) {
      /* XML processing instructions are ended by "?>" */
      if (s - beg < 4 || s[-2] != '?')
	goto FIND_PI_END;
      token_pos.end = s - 2;
    }

    /* a complete processing instruction seen */
    html_handle(p_state, E_PROCESS, beg, s, &token_pos, 1, self);
    return s;
  }
  else {
    return beg;
  }
  return 0;
}

static char*
html_parse_null(PSTATE* p_state, char *beg, char *end, SV* self)
{
  return 0;
}

#include "pfunc.h"  /* declares the html_parsefunc[] */

static void
html_parse(PSTATE* p_state,
	   SV* chunk,
	   SV* self)
{
  char *s, *t, *end, *new_pos;
  STRLEN len;

  if (!chunk || !SvOK(chunk)) {
    /* EOF */
    if (p_state->buf && SvOK(p_state->buf)) {
      /* flush it */
      STRLEN len;
      char *s = SvPV(p_state->buf, len);
      html_handle(p_state, E_TEXT, s, s+len, 0, 0, self);
#if 0
      flush_pending_text(p_state, self);
#endif
      SvREFCNT_dec(p_state->buf);
      p_state->buf = 0;
    }
    return;
  }

  if (p_state->buf && SvOK(p_state->buf)) {
    sv_catsv(p_state->buf, chunk);
    s = SvPV(p_state->buf, len);
  }
  else {
    s = SvPV(chunk, len);
  }

  if (!len)
    return; /* nothing to do */

  t = s;
  end = s + len;

  while (1) {
    /*
     * At the start of this loop we will always be ready for eating text
     * or a new tag.  We will never be inside some tag.  The 't' point
     * to where we started and the 's' is advanced as we go.
     */

    while (p_state->literal_mode) {
      char *l = p_state->literal_mode;
      char *end_text;

      while (s < end && *s != '<')
	s++;

      if (s == end) {
	s = t;
	goto DONE;
      }

      end_text = s;
      s++;
      
      /* here we rely on '\0' termination of perl svpv buffers */
      if (*s == '/') {
	s++;
	while (*l && toLOWER(*s) == *l) {
	  s++;
	  l++;
	}

	if (!*l) {
	  /* matched it all */
	  token_pos_t end_token;
	  end_token.beg = end_text + 1;
	  end_token.end = s;

	  while (isHSPACE(*s))
	    s++;
	  if (*s == '>') {
	    s++;
	    html_handle(p_state, E_TEXT, t, end_text, 0, 0, self);
	    html_handle(p_state, E_END,  end_text, s, &end_token, 1, self);
	    p_state->literal_mode = 0;
	    t = s;
	  }
	}
      }
    }

#ifdef MARKED_SECTION
    while (p_state->ms == MS_CDATA || p_state->ms == MS_RCDATA) {
      while (s < end && *s != ']')
	s++;
      if (*s == ']') {
	char *end_text = s;
	s++;
	if (*s == ']') {
	  s++;
	  if (*s == '>') {
	    s++;
	    if (*s == '\n')
	      s++;
	    /* marked section end */
	    html_handle(p_state, E_TEXT, t, end_text, 0, 0, self);
	    t = s;
	    SvREFCNT_dec(av_pop(p_state->ms_stack));
	    marked_section_update(p_state);
	    continue;
	  }
	}
      }
      if (s == end) {
	s = t;
	goto DONE;
      }
    }
#endif

    /* first we try to match as much text as possible */
    while (s < end && *s != '<') {
#ifdef MARKED_SECTION
      if (p_state->ms && *s == ']') {
	char *end_text = s;
	s++;
	if (*s == ']') {
	  s++;
	  if (*s == '>') {
	    s++;
	    if (*s == '\n')
	      s++;
	    html_handle(p_state, E_TEXT, t, end_text, 0, 0, self);
	    SvREFCNT_dec(av_pop(p_state->ms_stack));
	    marked_section_update(p_state);    
	    t = s;
	    continue;
	  }
	}
      }
#endif
      s++;
    }
    if (s != t) {
      if (*s == '<') {
	html_handle(p_state, E_TEXT, t, s, 0, 0, self);
	t = s;
      }
      else {
	s--;
	if (isHSPACE(*s)) {
	  /* wait with white space at end */
	  while (s >= t && isHSPACE(*s))
	    s--;
	}
	else {
	  /* might be a chopped up entities/words */
	  while (s >= t && !isHSPACE(*s))
	    s--;
	  while (s >= t && isHSPACE(*s))
	    s--;
	}
	s++;
	html_handle(p_state, E_TEXT, t, s, 0, 0, self);
	break;
      }
    }

    if (end - s < 3)
      break;

    /* next char is known to be '<' and pointed to by 't' as well as 's' */
    s++;

    if ( (new_pos = html_parsefunc[*s](p_state, t, end, self))) {
      if (new_pos == t) {
	/* no progress, need more data to know what it is */
	s = t;
	break;
      }
      t = s = new_pos;
    }

    /* if we get out here then this was not a conforming tag, so
     * treat it is plain text at the top of the loop again (we
     * have already skipped past the "<").
     */
  }

 DONE:

  if (s == end) {
    if (p_state->buf) {
      SvOK_off(p_state->buf);
    }
  }
  else {
    /* need to keep rest in buffer */
    if (p_state->buf) {
      /* chop off some chars at the beginning */
      if (SvOK(p_state->buf))
	sv_chop(p_state->buf, s);
      else
	sv_setpvn(p_state->buf, s, end - s);
    }
    else {
      p_state->buf = newSVpv(s, end - s);
    }
  }
  return;
}



static PSTATE*
get_pstate(SV* sv)
{
  HV* hv;
  SV** svp;

  sv = SvRV(sv);
  if (!sv || SvTYPE(sv) != SVt_PVHV)
    croak("Not a reference to a hash");
  hv = (HV*)sv;
  svp = hv_fetch(hv, "_parser_xs_state", 16, 0);
  if (svp) {
    PSTATE* p = (PSTATE*)SvIV(*svp);
#ifdef P_MAGIC
    if (p->magic != P_MAGIC)
      croak("Bad magic in parser state object at %p", p);
#endif
    return p;
  }
  croak("Can't find '_parser_xs_state' element in HTML::Parser hash");
  return 0;
}



MODULE = HTML::Parser		PACKAGE = HTML::Parser

PROTOTYPES: DISABLE

void
_alloc_pstate(self)
	SV* self;
    PREINIT:
	PSTATE* pstate;
	SV* sv;
	HV* hv;
    CODE:
	sv = SvRV(self);
        if (!sv || SvTYPE(sv) != SVt_PVHV)
            croak("Self is not a reference to a hash");
	hv = (HV*)sv;

	Newz(56, pstate, 1, PSTATE);
#ifdef P_MAGIC
	pstate->magic = P_MAGIC;
#endif
	sv = newSViv((IV)pstate);
	SvREADONLY_on(sv);

	hv_store(hv, "_parser_xs_state", 16, sv, 0);

void
DESTROY(pstate)
	PSTATE* pstate
    PREINIT:
        int i;
    CODE:
	SvREFCNT_dec(pstate->buf);
	SvREFCNT_dec(pstate->pending_text);
#ifdef MARKED_SECTION
        SvREFCNT_dec(pstate->ms_stack);
#endif
        SvREFCNT_dec(pstate->bool_attr_val);
        for (i = 0; i < EVENT_COUNT; i++) {
          SvREFCNT_dec(pstate->handlers[i].cb);
          SvREFCNT_dec(pstate->handlers[i].attrspec);
        }

	Safefree(pstate);


void
parse(self, chunk)
	SV* self;
	SV* chunk
    PREINIT:
	PSTATE* pstate = get_pstate(self);
    PPCODE:
	html_parse(pstate, chunk, self);
	XSRETURN(1); /* self */

SV*
strict_comment(pstate,...)
	PSTATE* pstate
    ALIAS:
	HTML::Parser::strict_comment = 1
	HTML::Parser::strict_names = 2
        HTML::Parser::xml_mode = 3
	HTML::Parser::unbroken_text = 4
        HTML::Parser::marked_sections = 5
    PREINIT:
	bool *attr;
    CODE:
        switch (ix) {
	case  1: attr = &pstate->strict_comment;       break;
	case  2: attr = &pstate->strict_names;         break;
	case  3: attr = &pstate->xml_mode;             break;
	case  4: attr = &pstate->unbroken_text;        break;
        case  5:
#ifdef MARKED_SECTION
		 attr = &pstate->marked_sections;      break;
#else
	         croak("marked sections not supported"); break;
#endif
	default:
	    croak("Unknown boolean attribute (%d)", ix);
        }
	RETVAL = boolSV(*attr);
	if (items > 1)
	    *attr = SvTRUE(ST(1));
    OUTPUT:
	RETVAL

SV*
bool_attr_value(pstate,...)
        PSTATE* pstate
    CODE:
	RETVAL = pstate->bool_attr_val ? newSVsv(pstate->bool_attr_val)
				       : &PL_sv_undef;
	if (items > 1) {
	    SvREFCNT_dec(pstate->bool_attr_val);
	    pstate->bool_attr_val = newSVsv(ST(1));
        }
    OUTPUT:
	RETVAL

void
handler(pstate, name_sv,...)
	PSTATE* pstate
	SV* name_sv
    PREINIT:
	STRLEN name_len;
	char *name = SvPV(name_sv, name_len);
        int event = -1;
        struct p_handler *h;
        int return_count;
    CODE:
	switch (name_len) {
	case 3:
	    if (strEQ(name, "end"))
	      event = E_END;
	    break;
	case 4:
	    if (strEQ(name, "text"))
	      event = E_TEXT;
	    break;
	case 5:
	    if (strEQ(name, "start"))
	      event = E_START;
	    break;
	case 7:
	    if (strEQ(name, "comment"))
	      event = E_COMMENT;
	    if (strEQ(name, "process"))
	      event = E_PROCESS;
	    if (strEQ(name, "default"))
	      event = E_DEFAULT;
	    break;
	case 11:
	    if (strEQ(name, "declaration"))
	      event = E_DECLARATION;
	    break;
	}

        if (event < 0)
	    croak("No %s handler", name);

	h = &pstate->handlers[event];
        ST(0) = h->attrspec;
        return_count = 1;
        if (GIMME_V == G_ARRAY) {
	  return_count = 2;
	  ST(1) = h->cb;
        }

        /* update */
        if (items > 2) {
	  SvREFCNT_dec(h->attrspec);
	  h->attrspec = SvREFCNT_inc(ST(2));
	  if (items > 3) {
	    SvREFCNT_dec(h->cb);
	    h->cb = SvREFCNT_inc(ST(3));
	    /* XXX should check for CODE reference */
	  }
	}

        XSRETURN(return_count);


MODULE = HTML::Parser		PACKAGE = HTML::Entities

void
decode_entities(...)
    PREINIT:
        int i;
    PPCODE:
	if (GIMME_V == G_SCALAR && items > 1)
            items = 1;
	for (i = 0; i < items; i++) {
	    if (GIMME_V != G_VOID)
	        ST(i) = sv_2mortal(newSVsv(ST(i)));
	    else if (SvREADONLY(ST(i)))
		croak("Can't inline decode readonly string");
	    decode_entities(ST(i), entity2char);
	}
        XSRETURN(items);


MODULE = HTML::Parser		PACKAGE = HTML::Parser

BOOT:
    entity2char = perl_get_hv("HTML::Entities::entity2char", TRUE);
